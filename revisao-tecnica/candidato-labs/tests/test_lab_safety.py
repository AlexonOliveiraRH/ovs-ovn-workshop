#!/usr/bin/env python3
"""Regressões locais com comandos simulados; não constituem validação E2E.

Uso: python3 -B tests/test_lab_safety.py
No pacote candidato: acrescentar --workshop-root /caminho/do/workshop
Contra o estado inicial: acrescentar --snapshot /caminho/workshop-antes.tar
O PATH restrito não contém SSH nem utilitários reais de administração.
"""

import argparse
import io
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
WORKSHOP_ROOT = ROOT
LABS = ROOT / "labs/standalone"
MOCKS = r'''
registrar() { printf '%s|%s|%s\n' "${MOCK_NODE:-central}" "$1" "${*:2}" >> "$MOCK_LOG"; }
bash() { /bin/bash --noprofile --norc "$@"; }
ssh() {
    [[ "$1" != -- ]] || shift
    local node="$1"; shift
    registrar ssh "$node"
    [[ "$node" != "${MOCK_SSH_FAIL:-}" ]] || return 255
    MOCK_NODE="${node#*@}" /bin/bash --noprofile --norc -c "$*"
}
id() { printf '0\n'; }
sleep() { :; }
systemctl() {
    registrar systemctl "$@"
    if [[ "$*" == 'is-active firewalld' ]]; then
        [[ "${MOCK_FIREWALL_ACTIVE:-0}" == 1 ]]
        return
    fi
    [[ "$*" != "${MOCK_SYSTEMCTL_FAIL:-}" ]] || return 7
    if [[ "$*" == 'enable --now openvswitch' ]]; then
        : > "$MOCK_DIR/ovs-ativo-${MOCK_NODE:-central}"
    fi
}
firewall-cmd() { registrar firewall-cmd "$@"; [[ "${MOCK_FIREWALL_FAIL:-0}" != 1 ]]; }
ovs-vsctl() {
    registrar ovs-vsctl "$@"
    if [[ "${MOCK_OVS_OFF:-0}" == 1 && ! -e "$MOCK_DIR/ovs-ativo-${MOCK_NODE:-central}" ]]; then
        return 7
    fi
    [[ "$*" != "${MOCK_OVS_FAIL:-}" ]] || return 7
    if [[ "$*" == 'get open_vswitch . external_ids:system-id' ]]; then
        printf '"old-%s"\n' "${MOCK_NODE:-central}"
    fi
}
ovs-ofctl() { registrar ovs-ofctl "$@"; }
ovs-appctl() { registrar ovs-appctl "$@"; }
ovn-appctl() {
    registrar ovn-appctl "$@"
    if [[ "${MOCK_DISCONNECTED:-}" == "${MOCK_NODE:-central}" ]]; then
        printf 'not connected\n'
    else
        printf 'connected\n'
    fi
}
ovn-nbctl() {
    registrar ovn-nbctl "$@"
    [[ "$*" != "${MOCK_NB_FAIL:-}" ]] || return 7
    case "$*" in
        *'find DHCP_Options external_ids:workshop=restore-ovn-lab')
            printf 'dhcp-lab\ndhcp-compartilhado\n' ;;
        *'find Logical_Switch_Port dhcpv4_options=dhcp-lab') printf 'vm1\nvm2\nvm3\n' ;;
        *'find Logical_Switch_Port dhcpv6_options=dhcp-compartilhado') printf 'cliente-porta\n' ;;
    esac
    [[ "$*" != 'create DHCP_Options'* ]] || printf 'dhcp-uuid\n'
    return 0
}
ovn-sbctl() {
    registrar ovn-sbctl "$@"
    [[ "$*" != "${MOCK_SB_FAIL:-}" ]] || return 7
    case "$*" in
        show) printf 'Chassis central\nChassis compute1\nChassis compute2\n' ;;
        '--data=bare --no-heading --columns=name list Chassis')
            printf 'central\n\ncompute1\n\ncompute2\n' ;;
        '--format=csv --data=bare --no-heading --columns=name list Chassis')
            printf 'central\ncompute1\n'
            [[ "${MOCK_CHASSIS_MISSING:-0}" == 1 ]] || printf 'compute2\n'
            [[ "${MOCK_CHASSIS_EXTRA:-0}" != 1 ]] || printf 'cliente-chassis\n' ;;
        'get Chassis '*' _uuid') printf 'uuid-%s\n' "$3" ;;
        'get Port_Binding '*' chassis')
            if [[ "$3" == "${MOCK_BINDING_MISSING:-}" ]]; then
                printf '[]\n'
            elif [[ "$3" == "${MOCK_BINDING_WRONG:-}" ]]; then
                printf 'uuid-compute2\n'
            elif [[ "$3" == vm3 ]]; then
                printf 'uuid-compute1\n'
            else
                printf 'uuid-central\n'
            fi ;;
        *'list chassis') printf 'old-central\nold-compute1\nold-compute2\ncliente-chassis\n' ;;
    esac
}
kill() {
    registrar kill "$@"
    local pid
    for pid in "$@"; do
        [[ "$pid" == -* ]] && continue
        : > "$MOCK_DIR/encerrado-$pid"
    done
}
ip() {
    registrar ip "$@"
    [[ "$*" != "${MOCK_IP_FAIL:-}" ]] || return 7
    case "$*" in
        'netns list')
            [[ "${MOCK_EMPTY_NS:-0}" != 1 ]] || return 0
            case "${MOCK_NODE:-central}" in
                central) printf 'vm1 (id: 1)\nvm2\nvm4\nvm5\nvm6\next-gw\ncliente-ns\n' ;;
                compute1) printf 'vm3\ncliente-ns\n' ;;
                compute2) printf 'cliente-ns\n' ;;
            esac ;;
        'netns pids vm4')
            local pid
            for pid in 424201 424202; do
                if [[ ! -e "$MOCK_DIR/encerrado-$pid" || "${MOCK_STUCK:-0}" == 1 ]]; then
                    printf '%s\n' "$pid"
                fi
            done ;;
        'netns exec '* )
            if [[ "$*" == *' ping '* ]]; then
                [[ "${MOCK_PING_FAIL:-}" != all && "${*: -1}" != "${MOCK_PING_FAIL:-}" ]]
            elif [[ "$*" == *' curl '* ]]; then
                [[ "${MOCK_HTTP_FAIL:-0}" != 1 ]]
            elif [[ "${MOCK_HTTP_PAYLOAD:-0}" == 1 && "$4" == python3 ]]; then
                printf '%s' "$7" > "$MOCK_DIR/http-$3.py"
            fi ;;
    esac
}
nohup() { registrar nohup "$@"; "$@"; }
nc() { registrar nc "$@"; }
python3() { registrar python3 "$@"; }
curl() { registrar curl "$@"; [[ "${MOCK_HTTP_FAIL:-0}" != 1 ]]; }
find() { registrar find "$@"; printf '/tmp/cloud-init-cliente\n'; }
rm() { registrar rm "$@"; }
[[ "${MOCK_NO_PYTHON:-}" != "${MOCK_NODE:-central}" ]] || unset -f python3
'''


class SegurancaLab(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="ovn-mocks-")
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name)
        self.log = self.directory / "comandos.log"
        mocks = self.directory / "ambiente.sh"
        mocks.write_text(MOCKS, encoding="utf-8")
        bindir = self.directory / "bin"
        bindir.mkdir()
        for name in ("bash", "dirname", "grep", "sed", "tr", "seq"):
            (bindir / name).symlink_to(shutil.which(name))
        self.env = {
            "PATH": str(bindir), "BASH_ENV": str(mocks),
            "MOCK_LOG": str(self.log), "MOCK_DIR": str(self.directory),
            "CENTRAL": "root@central", "COMPUTE1": "root@compute1",
            "COMPUTE2": "root@compute2", "CENTRAL_IP": "192.0.2.10",
            "COMPUTE1_IP": "192.0.2.11", "COMPUTE2_IP": "192.0.2.12",
            "LC_ALL": "C.UTF-8",
        }

    def executar(self, name="restore-ovn-lab.sh", target="10", trecho=None, **env):
        script = LABS / name
        if trecho is None:
            command = ["/bin/bash", str(script), target]
        else:
            marker, call = trecho
            definitions = script.read_text(encoding="utf-8").split(marker)[0]
            fragment = self.directory / "trecho.sh"
            fragment.write_text(definitions + "\n" + call, encoding="utf-8")
            helper = self.directory / "lab-netns.sh"
            if not helper.exists() and (LABS / "lab-netns.sh").exists():
                helper.symlink_to(LABS / "lab-netns.sh")
            command = ["/bin/bash", str(fragment), target]
        result = subprocess.run(command, env=self.env | env, capture_output=True,
                                text=True, timeout=15, cwd=ROOT)
        calls = self.log.read_text(encoding="utf-8") if self.log.exists() else ""
        self.assertNotIn("command not found", result.stderr, result.stderr)
        return result, calls

    def test_restauracao_simulada_sem_falhas(self):
        for target in ("1", "2", "3", "4", "5", "6", "7", "8", "9", "10"):
            with self.subTest(target=target):
                result, _ = self.executar(target=target)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_ping_negativo_falha_sem_anunciar_sucesso(self):
        for address in ("10.0.0.12", "10.0.0.11", "10.0.1.11", "172.16.0.1"):
            with self.subTest(address=address):
                result, _ = self.executar(MOCK_PING_FAIL=address)
                self.assertIn("FAIL", result.stdout)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertNotIn("Lab restored", result.stdout)

    def test_erro_no_meio_do_bloco_remoto_interrompe(self):
        result, calls = self.executar(target="2", MOCK_NB_FAIL="ls-add network1")
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertNotIn("|ovn-nbctl|lsp-add", calls)

    def test_erro_local_tambem_interrompe(self):
        result, calls = self.executar(target="2", CENTRAL="local", MOCK_NB_FAIL="ls-add network1")
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertNotIn("|ovn-nbctl|lsp-add", calls)

    def test_pipeline_remoto_propaga_falha(self):
        result, _ = self.executar(trecho=("# Main", "get_central_system_id"),
                                 MOCK_OVS_FAIL="get open_vswitch . external_ids:system-id")
        self.assertEqual(result.returncode, 7, result.stderr)

    def test_variavel_remota_nao_definida_falha(self):
        result, _ = self.executar(trecho=("# Main", "run_central 'echo \"$AUSENTE\"; echo indevido'"))
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("indevido", result.stdout)

    def test_ssh_indisponivel_interrompe_antes_de_mutacoes(self):
        for node in ("root@central", "root@compute1", "root@compute2"):
            with self.subTest(node=node):
                result, calls = self.executar(target="1", MOCK_SSH_FAIL=node)
                self.assertEqual(result.returncode, 255)
                self.assertNotIn("|systemctl|enable", calls)
                self.assertNotIn("netns del", calls)

    def test_inicia_ovs_antes_da_limpeza_que_acessa_ovsdb(self):
        result, _ = self.executar(target="2", MOCK_OVS_OFF="1")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_falhas_criticas_interrompem_configuracao(self):
        for failure in ({"MOCK_SYSTEMCTL_FAIL": "stop ovn-controller"},
                        {"MOCK_NB_FAIL": "--if-exists ls-del network1"},
                        {"MOCK_SB_FAIL": "--if-exists chassis-del old-central"},
                        {"MOCK_IP_FAIL": "netns pids vm3"}):
            with self.subTest(failure=failure):
                result, calls = self.executar(target="2", **failure)
                self.assertEqual(result.returncode, 7)
                self.assertNotIn("|ovn-nbctl|ls-add network1", calls)

    def test_firewall_ativo_propaga_erro(self):
        result, calls = self.executar(target="1", MOCK_FIREWALL_ACTIVE="1", MOCK_FIREWALL_FAIL="1")
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("chassis-del", calls)

    def test_dependencia_http_ausente_interrompe_antes_de_mutacoes(self):
        for node in ("central",):
            with self.subTest(node=node):
                result, calls = self.executar(target="9", MOCK_NO_PYTHON=node)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("|systemctl|enable", calls)
                self.assertNotIn("netns del", calls)

    def test_compute2_sem_python_nao_impede_restauracao(self):
        result, _ = self.executar(target="9", MOCK_NO_PYTHON="compute2")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_dhcp_novo_tem_marca_de_propriedade(self):
        result, calls = self.executar(target="4")
        self.assertEqual(result.returncode, 0, result.stderr)
        creation = next(line for line in calls.splitlines() if "|ovn-nbctl|create DHCP_Options " in line)
        self.assertIn("external_ids:workshop=restore-ovn-lab", creation)

    def test_cleanup_dhcp_preserva_registros_compartilhados_e_sem_marca(self):
        result, calls = self.executar(trecho=("# Main", "cleanup"))
        self.assertEqual(result.returncode, 0, result.stderr)
        removals = [line for line in calls.splitlines() if "|ovn-nbctl|destroy DHCP_Options " in line]
        self.assertEqual(removals, ["central|ovn-nbctl|destroy DHCP_Options dhcp-lab"])

    def test_consulta_dhcp_falha_interrompe_antes_de_excluir_switches(self):
        result, calls = self.executar(trecho=("# Main", "cleanup"), MOCK_NB_FAIL=
            "--format=csv --data=bare --no-heading --columns=_uuid find DHCP_Options external_ids:workshop=restore-ovn-lab")
        self.assertEqual(result.returncode, 7)
        self.assertNotIn("|ovn-nbctl|--if-exists ls-del", calls)

    def test_ovs_informa_estado_final_e_base_dos_alvos_avancados(self):
        for target in ("6", "7", "10"):
            with self.subTest(target=target):
                result, _ = self.executar(name="restore-lab.sh", target=target)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("Estado: fim do exercício 6", result.stdout)
                self.assertNotIn("Ready for:", result.stdout)

    def test_verificacao_rejeita_chassis_e_bindings_incompletos(self):
        failures = ({"MOCK_CHASSIS_MISSING": "1"},
                    {"MOCK_BINDING_MISSING": "vm1"},
                    {"MOCK_BINDING_WRONG": "vm3"})
        for failure in failures:
            with self.subTest(failure=failure):
                result, _ = self.executar(trecho=("# Main", "verify"), **failure)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertNotIn("Lab restored", result.stdout)

    def test_chassis_externo_preservado_nao_impede_verificacao(self):
        result, calls = self.executar(MOCK_CHASSIS_EXTRA="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("chassis-del cliente-chassis", calls)

    def test_verificacao_rejeita_controller_desconectado(self):
        for node in ("central", "compute1", "compute2"):
            with self.subTest(node=node):
                result, _ = self.executar(trecho=("# Main", "verify"),
                                         MOCK_DISCONNECTED=node)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertNotIn("Lab restored", result.stdout)

    def test_entradas_perigosas_rejeitadas_antes_do_ssh(self):
        values = {
            "CENTRAL_IP": ("192.0.2.10; printf INJETADO", "$(printf INJETADO)",
                           "192.0.2.10\ntrue", "999.0.0.1", "01.2.3.4", "::1"),
            "COMPUTE1_IP": ("192.0.2.11`printf INJETADO`", "192.0.2.11/24"),
            "COMPUTE2_IP": ("192.0.2.12 && true", "192.0.2.12 extra"),
            "CENTRAL": ("-oProxyCommand=printf", "root@host;true", "root@host\ntrue"),
            "COMPUTE1": ("-F/dev/null", "root@$(printf INJETADO)", "local"),
            "COMPUTE2": ("root@host extra", "root@host'", "local"),
        }
        for key, invalid_values in values.items():
            for value in invalid_values:
                with self.subTest(key=key, value=value):
                    # Executa a inicialização, sem oferecer uma chance de executar a injeção.
                    result, calls = self.executar(trecho=("# Main", ":"), **{key: value})
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(calls, "")

    def test_destino_ssh_valido_mantem_argumento_unico(self):
        result, calls = self.executar(target="1", CENTRAL="lab-user@central.example",
                                     CENTRAL_IP="10.255.0.1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("|ssh|lab-user@central.example\n", calls)

    def test_namespaces_ausentes_nao_sao_erro(self):
        result, calls = self.executar(target="1", MOCK_EMPTY_NS="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("netns del", calls)

    def test_cleanup_nao_remove_recursos_alheios(self):
        result, calls = self.executar(target="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("netns del cliente-ns", calls)
        self.assertNotIn("chassis-del cliente-chassis", calls)
        self.assertNotIn("flush-conntrack", calls)
        for name in ("old-central", "old-compute1", "old-compute2"):
            self.assertIn("chassis-del " + name, calls)

    def test_processos_encerrados_antes_de_remover_namespace(self):
        result, calls = self.executar(target="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        for pid in ("424201", "424202"):
            self.assertIn("|kill|" + pid, calls)
            self.assertLess(calls.index("|kill|" + pid), calls.index("netns del vm4"))

    def test_processos_resistentes_impedem_exclusao(self):
        result, calls = self.executar(target="1", MOCK_STUCK="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("netns del vm4", calls)

    def test_cleanup_nao_mascara_erro_de_exclusao(self):
        result, calls = self.executar(target="1", MOCK_IP_FAIL="netns del vm1")
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertNotIn("|systemctl|enable --now ovn-controller", calls)

    def test_target_9_inicia_backends_e_verifica_http(self):
        result, calls = self.executar(target="9")
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in ("vm4", "vm5", "vm6"):
            self.assertIn("|nohup|ip netns exec " + name + " python3 -u -c", calls)
        self.assertIn("http://10.0.1.100", calls)
        self.assertIn("--connect-timeout 2 --max-time 10", calls)
        self.assertNotIn("|nc|", calls)

    def test_acl_exercicio_7_corresponde_a_lista_documentada(self):
        doc = (WORKSHOP_ROOT / "content/modules/ROOT/pages/05-ovn-hands-on.adoc").read_text(encoding="utf-8")
        documented = []
        for line in doc.replace("\\\n", " ").splitlines():
            if line.startswith("sudo ovn-nbctl acl-add "):
                documented.append(" ".join(shlex.split(line)[2:]))
        self.assertEqual(len(documented), 6, "Revisar a lista de ACLs do workshop")
        result, calls = self.executar(target="7")
        self.assertEqual(result.returncode, 0, result.stderr)
        applied = [line.split("|", 2)[2] for line in calls.splitlines()
                   if "|ovn-nbctl|acl-add " in line]
        self.assertEqual(applied, documented)
        self.assertNotIn("acl-del", calls)

    def test_http_negativo_falha(self):
        result, _ = self.executar(target="9", MOCK_HTTP_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Lab restored", result.stdout)

    def test_payload_http_dos_backends_sem_abrir_sockets(self):
        result, _ = self.executar(target="9", MOCK_HTTP_PAYLOAD="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        for ns in ("vm4", "vm5", "vm6"):
            payload = self.directory / ("http-" + ns + ".py")
            # Os backends são iniciados em segundo plano, inclusive no mock.
            for _ in range(100):
                if payload.exists() and payload.stat().st_size > 0:
                    break
                time.sleep(0.01)
            self.assertTrue(payload.exists(), "Backend não recebeu código Python: " + ns)
            # Apenas o bind/listen é simulado. O parser HTTP e o handler são reais.
            for label in (ns, "backend-com-nome-maior"):
                namespace = {}
                with mock.patch("http.server.HTTPServer"), mock.patch.object(sys, "argv", ["-c", label]):
                    exec(compile(payload.read_text(), str(payload), "exec"), namespace)
                for path in ("/", "/../../etc/passwd"):
                    request = mock.Mock()
                    request.makefile.return_value = io.BytesIO(
                        ("GET " + path + " HTTP/1.1\r\nHost: lab\r\n\r\n").encode())
                    with mock.patch.object(namespace["Handler"], "log_message"):
                        namespace["Handler"](request, ("192.0.2.20", 12345), mock.Mock())
                    response = b"".join(c.args[0] for c in request.sendall.call_args_list)
                    headers, body = response.split(b"\r\n\r\n", 1)
                    self.assertIn(b"200 OK", headers)
                    self.assertIn(b"Content-Type: text/plain", headers)
                    self.assertEqual(body, ("Server: " + label + "\n").encode("ascii"))
                    self.assertIn(("Content-Length: " + str(len(body))).encode(), headers)

    def test_target_invalido_nao_executa_limpeza(self):
        for name in ("restore-ovn-lab.sh", "restore-lab.sh"):
            for target in ("abc", "0", "11", "1+1"):
                with self.subTest(name=name, target=target):
                    self.log.write_text("", encoding="utf-8")
                    result, calls = self.executar(name=name, target=target)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(calls, "")

    def test_ovs_preserva_qos_alheio(self):
        result, calls = self.executar(name="restore-lab.sh", target="3")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("--all destroy", calls)

    def test_ovs_ping_negativo_mantem_exit_1(self):
        result, _ = self.executar(name="restore-lab.sh", target="3", MOCK_PING_FAIL="all")
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("Lab Restored", result.stdout)
        self.assertNotIn("Ready for", result.stdout)

    def test_kvm_preserva_temporarios_sem_propriedade_comprovada(self):
        # Só executa esta função; não carrega nem executa o provisionamento.
        source = (LABS / "kvm/teardown.sh").read_text(encoding="utf-8")
        body = source.split("clean_temp_files() {", 1)[1].split("\n}", 1)[0]
        fragment = self.directory / "limpeza-kvm.sh"
        fragment.write_text("DRY_RUN=false\ninfo() { :; }; warn() { :; }\n"
                            "clean_temp_files() {\n" + body + "\n}\nclean_temp_files\n",
                            encoding="utf-8")
        result = subprocess.run(["/bin/bash", str(fragment)],
                                env=self.env, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.log.read_text(encoding="utf-8") if self.log.exists() else ""
        self.assertNotIn("|rm|", calls)

    def executar_teardown_kvm(self, **env):
        source = (LABS / "kvm/teardown.sh").read_text(encoding="utf-8")
        common = (LABS / "kvm/common.sh").read_text(encoding="utf-8")
        definitions = []
        for name, text in (("find_prefix_vms", source), ("remove_vms", source),
                           ("teardown_prefix", source), ("vm_is_running", common)):
            body = text.split(name + "() {", 1)[1].split("\n}", 1)[0]
            definitions.append(name + "() {" + body + "\n}\n")
        setup = r'''
set -euo pipefail
DRY_RUN=${MOCK_DRY_RUN:-false}
FORCE=true
declare -a REMOVED_VMS=()
info() { :; }; header() { :; }; list_resources() { :; }
success() { printf 'SUCESSO: %s\n' "$*"; }
error() { printf 'ERRO: %s\n' "$*" >&2; }
virsh() {
    registrar virsh "$@"
    [[ "$1" != "${MOCK_VIRSH_FAIL:-}" ]] || return 7
    case "$1" in
        list) printf 'ovnlab-central\ncliente-vm\n' ;;
        domstate) printf '%s\n' "${MOCK_VM_STATE:-running}" ;;
        snapshot-list) printf 'snapshot-lab\n' ;;
        undefine)
            if [[ "${MOCK_NVRAM_FAIL:-0}" == 1 && "$*" == *'--nvram'* ]]; then
                return 7
            fi ;;
    esac
}
remove_ovs_bridges() { registrar posterior bridges; }
remove_networks() { registrar posterior networks; }
remove_storage_files() { registrar posterior storage; }
clean_temp_files() { registrar posterior temp; }
'''
        fragment = self.directory / "teardown-kvm.sh"
        fragment.write_text(setup + "\n".join(definitions) + '\nteardown_prefix "ovnlab"\n',
                            encoding="utf-8")
        self.log.write_text("", encoding="utf-8")
        result = subprocess.run(["/bin/bash", str(fragment)], env=self.env | env,
                                capture_output=True, text=True, timeout=5)
        self.assertNotIn("command not found", result.stderr)
        return result, self.log.read_text(encoding="utf-8")

    def test_kvm_falha_na_remocao_interrompe_antes_de_redes_e_storage(self):
        for command in ("list", "domstate", "destroy", "snapshot-list", "snapshot-delete", "undefine"):
            with self.subTest(command=command):
                result, calls = self.executar_teardown_kvm(MOCK_VIRSH_FAIL=command)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("SUCESSO:", result.stdout)
                self.assertNotIn("|posterior|", calls)

    def test_kvm_estados_e_fallback_preservam_escopo(self):
        for state in ("running", "paused", "shut off"):
            with self.subTest(state=state):
                result, calls = self.executar_teardown_kvm(MOCK_VM_STATE=state, MOCK_NVRAM_FAIL="1")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("SUCESSO:", result.stdout)
                self.assertEqual("|virsh|destroy ovnlab-central\n" in calls, state != "shut off")
                self.assertIn("|virsh|undefine ovnlab-central --remove-all-storage\n", calls)
                self.assertNotIn("|virsh|undefine ovnlab-central\n", calls)
                self.assertNotIn("cliente-vm", calls)

    def test_kvm_dry_run_nao_altera_vm(self):
        result, calls = self.executar_teardown_kvm(MOCK_DRY_RUN="true")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("|virsh|destroy", calls)
        self.assertNotIn("|virsh|undefine", calls)
        self.assertNotIn("|virsh|snapshot-delete", calls)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--snapshot", help="Executar contra o snapshot inicial, sem alterar o workspace")
    parser.add_argument("--workshop-root", type=Path, default=ROOT,
                        help="Raiz do workshop; somente leitura da documentação de referência")
    args, remaining = parser.parse_known_args()
    WORKSHOP_ROOT = args.workshop_root.resolve()
    with tempfile.TemporaryDirectory(prefix="ovn-regressao-") as baseline:
        if args.snapshot:
            with tarfile.open(args.snapshot) as archive:
                members = [m for m in archive.getmembers()
                           if m.name.startswith("labs/standalone/") and m.isfile()]
                archive.extractall(baseline, members=members, filter="data")
            LABS = Path(baseline) / "labs/standalone"
        result = unittest.main(argv=[sys.argv[0], *remaining], verbosity=2, exit=False)
    sys.exit(not result.result.wasSuccessful())
