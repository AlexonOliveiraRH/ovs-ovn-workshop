#!/usr/bin/env python3
"""Local regression tests with mocked commands; these do not validate a live lab.

Usage: python3 -B tests/test_lab_safety.py
The restricted PATH contains no real SSH or system administration utilities.
"""

import io
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
LABS = ROOT / "labs/standalone"
MOCKS = r'''
record_call() { printf '%s|%s|%s\n' "${MOCK_NODE:-central}" "$1" "${*:2}" >> "$MOCK_LOG"; }
bash() { /bin/bash --noprofile --norc "$@"; }
ssh() {
    [[ "$1" != -- ]] || shift
    local node="$1"; shift
    record_call ssh "$node"
    [[ "$node" != "${MOCK_SSH_FAIL:-}" ]] || return 255
    MOCK_NODE="${node#*@}" /bin/bash --noprofile --norc -c "$*"
}
id() { printf '0\n'; }
sleep() { :; }
systemctl() {
    record_call systemctl "$@"
    if [[ "$*" == 'is-active firewalld' ]]; then
        [[ "${MOCK_FIREWALL_ACTIVE:-0}" == 1 ]]
        return
    fi
    [[ "$*" != "${MOCK_SYSTEMCTL_FAIL:-}" ]] || return 7
    if [[ "$*" == 'enable --now openvswitch' ]]; then
        : > "$MOCK_DIR/ovs-active-${MOCK_NODE:-central}"
    fi
}
firewall-cmd() { record_call firewall-cmd "$@"; [[ "${MOCK_FIREWALL_FAIL:-0}" != 1 ]]; }
ovs-vsctl() {
    record_call ovs-vsctl "$@"
    if [[ "${MOCK_OVS_OFF:-0}" == 1 && ! -e "$MOCK_DIR/ovs-active-${MOCK_NODE:-central}" ]]; then
        return 7
    fi
    [[ "$*" != "${MOCK_OVS_FAIL:-}" ]] || return 7
    if [[ "$*" == 'get open_vswitch . external_ids:system-id' ]]; then
        printf '"old-%s"\n' "${MOCK_NODE:-central}"
    fi
}
ovs-ofctl() { record_call ovs-ofctl "$@"; }
ovs-appctl() { record_call ovs-appctl "$@"; }
ovn-appctl() {
    record_call ovn-appctl "$@"
    if [[ "${MOCK_DISCONNECTED:-}" == "${MOCK_NODE:-central}" ]]; then
        printf 'not connected\n'
    else
        printf 'connected\n'
    fi
}
ovn-nbctl() {
    record_call ovn-nbctl "$@"
    [[ "$*" != "${MOCK_NB_FAIL:-}" ]] || return 7
    case "$*" in
        *'find DHCP_Options external_ids:workshop=restore-ovn-lab')
            printf 'dhcp-lab\ndhcp-shared\n' ;;
        *'find Logical_Switch_Port dhcpv4_options=dhcp-lab') printf 'vm1\nvm2\nvm3\n' ;;
        *'find Logical_Switch_Port dhcpv6_options=dhcp-shared') printf 'unrelated-port\n' ;;
    esac
    [[ "$*" != 'create DHCP_Options'* ]] || printf 'dhcp-uuid\n'
    return 0
}
ovn-sbctl() {
    record_call ovn-sbctl "$@"
    [[ "$*" != "${MOCK_SB_FAIL:-}" ]] || return 7
    case "$*" in
        show) printf 'Chassis central\nChassis compute1\nChassis compute2\n' ;;
        '--data=bare --no-heading --columns=name list Chassis')
            printf 'central\n\ncompute1\n\ncompute2\n' ;;
        '--format=csv --data=bare --no-heading --columns=name list Chassis')
            printf 'central\ncompute1\n'
            [[ "${MOCK_CHASSIS_MISSING:-0}" == 1 ]] || printf 'compute2\n'
            [[ "${MOCK_CHASSIS_EXTRA:-0}" != 1 ]] || printf 'unrelated-chassis\n' ;;
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
        *'list chassis') printf 'old-central\nold-compute1\nold-compute2\nunrelated-chassis\n' ;;
    esac
}
kill() {
    record_call kill "$@"
    local pid
    for pid in "$@"; do
        [[ "$pid" == -* ]] && continue
        : > "$MOCK_DIR/terminated-$pid"
    done
}
ip() {
    record_call ip "$@"
    [[ "$*" != "${MOCK_IP_FAIL:-}" ]] || return 7
    case "$*" in
        'netns list')
            [[ "${MOCK_EMPTY_NS:-0}" != 1 ]] || return 0
            case "${MOCK_NODE:-central}" in
                central) printf 'vm1 (id: 1)\nvm2\nvm4\nvm5\nvm6\next-gw\nunrelated-ns\n' ;;
                compute1) printf 'vm3\nunrelated-ns\n' ;;
                compute2) printf 'unrelated-ns\n' ;;
            esac ;;
        'netns pids vm4')
            local pid
            for pid in 424201 424202; do
                if [[ ! -e "$MOCK_DIR/terminated-$pid" || "${MOCK_STUCK:-0}" == 1 ]]; then
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
nohup() { record_call nohup "$@"; "$@"; }
nc() { record_call nc "$@"; }
python3() { record_call python3 "$@"; }
curl() { record_call curl "$@"; [[ "${MOCK_HTTP_FAIL:-0}" != 1 ]]; }
[[ "${MOCK_NO_PYTHON:-}" != "${MOCK_NODE:-central}" ]] || unset -f python3
'''


class LabSafetyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="ovn-mocks-")
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name)
        self.log = self.directory / "commands.log"
        mocks = self.directory / "environment.sh"
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

    def run_script(self, name="restore-ovn-lab.sh", target="10", fragment=None, **env):
        script = LABS / name
        if fragment is None:
            command = ["/bin/bash", str(script), target]
        else:
            marker, call = fragment
            definitions = script.read_text(encoding="utf-8").split(marker)[0]
            fragment = self.directory / "fragment.sh"
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

    def test_mocked_restore_succeeds(self):
        for target in ("1", "2", "3", "4", "5", "6", "7", "8", "9", "10"):
            with self.subTest(target=target):
                result, _ = self.run_script(target=target)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_ping_failure_exits_without_reporting_success(self):
        for address in ("10.0.0.12", "10.0.0.11", "10.0.1.11", "172.16.0.1"):
            with self.subTest(address=address):
                result, _ = self.run_script(MOCK_PING_FAIL=address)
                self.assertIn("FAIL", result.stdout)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertNotIn("Lab restored", result.stdout)

    def test_error_in_remote_block_stops_execution(self):
        result, calls = self.run_script(target="2", MOCK_NB_FAIL="ls-add network1")
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertNotIn("|ovn-nbctl|lsp-add", calls)

    def test_local_error_stops_execution(self):
        result, calls = self.run_script(target="2", CENTRAL="local", MOCK_NB_FAIL="ls-add network1")
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertNotIn("|ovn-nbctl|lsp-add", calls)

    def test_remote_pipeline_propagates_failure(self):
        result, _ = self.run_script(fragment=("# Main", "get_central_system_id"),
                                 MOCK_OVS_FAIL="get open_vswitch . external_ids:system-id")
        self.assertEqual(result.returncode, 7, result.stderr)

    def test_unset_remote_variable_fails(self):
        result, _ = self.run_script(fragment=("# Main", "run_central 'echo \"$UNSET_VARIABLE\"; echo unexpected'"))
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("unexpected", result.stdout)

    def test_unavailable_ssh_stops_before_mutations(self):
        for node in ("root@central", "root@compute1", "root@compute2"):
            with self.subTest(node=node):
                result, calls = self.run_script(target="1", MOCK_SSH_FAIL=node)
                self.assertEqual(result.returncode, 255)
                self.assertNotIn("|systemctl|enable", calls)
                self.assertNotIn("netns del", calls)

    def test_ovs_starts_before_cleanup_accesses_ovsdb(self):
        result, _ = self.run_script(target="2", MOCK_OVS_OFF="1")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_critical_failures_stop_configuration(self):
        for failure in ({"MOCK_SYSTEMCTL_FAIL": "stop ovn-controller"},
                        {"MOCK_NB_FAIL": "--if-exists ls-del network1"},
                        {"MOCK_SB_FAIL": "--if-exists chassis-del old-central"},
                        {"MOCK_IP_FAIL": "netns pids vm3"}):
            with self.subTest(failure=failure):
                result, calls = self.run_script(target="2", **failure)
                self.assertEqual(result.returncode, 7)
                self.assertNotIn("|ovn-nbctl|ls-add network1", calls)

    def test_active_firewall_propagates_error(self):
        result, calls = self.run_script(target="1", MOCK_FIREWALL_ACTIVE="1", MOCK_FIREWALL_FAIL="1")
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("chassis-del", calls)

    def test_missing_http_dependency_stops_before_mutations(self):
        for node in ("central",):
            with self.subTest(node=node):
                result, calls = self.run_script(target="9", MOCK_NO_PYTHON=node)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("|systemctl|enable", calls)
                self.assertNotIn("netns del", calls)

    def test_missing_python_on_compute2_does_not_block_restore(self):
        result, _ = self.run_script(target="9", MOCK_NO_PYTHON="compute2")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_new_dhcp_options_have_ownership_tag(self):
        result, calls = self.run_script(target="4")
        self.assertEqual(result.returncode, 0, result.stderr)
        creation = next(line for line in calls.splitlines() if "|ovn-nbctl|create DHCP_Options " in line)
        self.assertIn("external_ids:workshop=restore-ovn-lab", creation)

    def test_dhcp_cleanup_preserves_shared_and_untagged_records(self):
        result, calls = self.run_script(fragment=("# Main", "cleanup"))
        self.assertEqual(result.returncode, 0, result.stderr)
        removals = [line for line in calls.splitlines() if "|ovn-nbctl|destroy DHCP_Options " in line]
        self.assertEqual(removals, ["central|ovn-nbctl|destroy DHCP_Options dhcp-lab"])

    def test_dhcp_query_failure_stops_before_switch_deletion(self):
        result, calls = self.run_script(fragment=("# Main", "cleanup"), MOCK_NB_FAIL=
            "--format=csv --data=bare --no-heading --columns=_uuid find DHCP_Options external_ids:workshop=restore-ovn-lab")
        self.assertEqual(result.returncode, 7)
        self.assertNotIn("|ovn-nbctl|--if-exists ls-del", calls)

    def test_ovs_reports_final_state_for_advanced_targets(self):
        for target in ("6", "7", "10"):
            with self.subTest(target=target):
                result, _ = self.run_script(name="restore-lab.sh", target=target)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("State: end of Exercise 6", result.stdout)
                self.assertNotIn("Ready for:", result.stdout)

    def test_verification_rejects_incomplete_chassis_and_bindings(self):
        failures = ({"MOCK_CHASSIS_MISSING": "1"},
                    {"MOCK_BINDING_MISSING": "vm1"},
                    {"MOCK_BINDING_WRONG": "vm3"})
        for failure in failures:
            with self.subTest(failure=failure):
                result, _ = self.run_script(fragment=("# Main", "verify"), **failure)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertNotIn("Lab restored", result.stdout)

    def test_preserved_unrelated_chassis_does_not_block_verification(self):
        result, calls = self.run_script(MOCK_CHASSIS_EXTRA="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("chassis-del unrelated-chassis", calls)

    def test_verification_rejects_disconnected_controller(self):
        for node in ("central", "compute1", "compute2"):
            with self.subTest(node=node):
                result, _ = self.run_script(fragment=("# Main", "verify"),
                                         MOCK_DISCONNECTED=node)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertNotIn("Lab restored", result.stdout)

    def test_unsafe_inputs_are_rejected_before_ssh(self):
        values = {
            "CENTRAL_IP": ("192.0.2.10; printf INJECTED", "$(printf INJECTED)",
                           "192.0.2.10\ntrue", "999.0.0.1", "01.2.3.4", "::1"),
            "COMPUTE1_IP": ("192.0.2.11`printf INJECTED`", "192.0.2.11/24"),
            "COMPUTE2_IP": ("192.0.2.12 && true", "192.0.2.12 extra"),
            "CENTRAL": ("-oProxyCommand=printf", "root@host;true", "root@host\ntrue"),
            "COMPUTE1": ("-F/dev/null", "root@$(printf INJECTED)", "local"),
            "COMPUTE2": ("root@host extra", "root@host'", "local"),
        }
        for key, invalid_values in values.items():
            for value in invalid_values:
                with self.subTest(key=key, value=value):
                    # Run initialization without allowing the injected command to execute.
                    result, calls = self.run_script(fragment=("# Main", ":"), **{key: value})
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(calls, "")

    def test_valid_ssh_destination_remains_one_argument(self):
        result, calls = self.run_script(target="1", CENTRAL="lab-user@central.example",
                                     CENTRAL_IP="10.255.0.1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("|ssh|lab-user@central.example\n", calls)

    def test_absent_namespaces_are_not_errors(self):
        result, calls = self.run_script(target="1", MOCK_EMPTY_NS="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("netns del", calls)

    def test_cleanup_preserves_unrelated_resources(self):
        result, calls = self.run_script(target="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("netns del unrelated-ns", calls)
        self.assertNotIn("chassis-del unrelated-chassis", calls)
        self.assertNotIn("flush-conntrack", calls)
        for name in ("old-central", "old-compute1", "old-compute2"):
            self.assertIn("chassis-del " + name, calls)

    def test_processes_stop_before_namespace_deletion(self):
        result, calls = self.run_script(target="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        for pid in ("424201", "424202"):
            self.assertIn("|kill|" + pid, calls)
            self.assertLess(calls.index("|kill|" + pid), calls.index("netns del vm4"))

    def test_lingering_processes_prevent_namespace_deletion(self):
        result, calls = self.run_script(target="1", MOCK_STUCK="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("netns del vm4", calls)

    def test_cleanup_does_not_hide_deletion_errors(self):
        result, calls = self.run_script(target="1", MOCK_IP_FAIL="netns del vm1")
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertNotIn("|systemctl|enable --now ovn-controller", calls)

    def test_target_9_starts_backends_and_checks_http(self):
        result, calls = self.run_script(target="9")
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in ("vm4", "vm5", "vm6"):
            self.assertIn("|nohup|ip netns exec " + name + " python3 -u -c", calls)
        self.assertIn("http://10.0.1.100", calls)
        self.assertIn("--connect-timeout 2 --max-time 10", calls)
        self.assertNotIn("|nc|", calls)

    def test_exercise_7_acls_match_documented_list(self):
        doc = (ROOT / "content/modules/ROOT/pages/05-ovn-hands-on.adoc").read_text(encoding="utf-8")
        documented = []
        for line in doc.replace("\\\n", " ").splitlines():
            if line.startswith("sudo ovn-nbctl acl-add "):
                documented.append(" ".join(shlex.split(line)[2:]))
        self.assertEqual(len(documented), 6, "Check the workshop ACL list")
        result, calls = self.run_script(target="7")
        self.assertEqual(result.returncode, 0, result.stderr)
        applied = [line.split("|", 2)[2] for line in calls.splitlines()
                   if "|ovn-nbctl|acl-add " in line]
        self.assertEqual(applied, documented)
        self.assertNotIn("acl-del", calls)

    def test_http_failure_causes_restore_failure(self):
        result, _ = self.run_script(target="9", MOCK_HTTP_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Lab restored", result.stdout)

    def test_backend_http_responses_without_opening_sockets(self):
        result, _ = self.run_script(target="9", MOCK_HTTP_PAYLOAD="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        for ns in ("vm4", "vm5", "vm6"):
            payload = self.directory / ("http-" + ns + ".py")
            # Backends start in the background, including in the mock.
            for _ in range(100):
                if payload.exists() and payload.stat().st_size > 0:
                    break
                time.sleep(0.01)
            self.assertTrue(payload.exists(), "Backend did not receive Python code: " + ns)
            # Only bind/listen is mocked. The HTTP parser and handler are real.
            for label in (ns, "backend-with-longer-name"):
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

    def test_invalid_target_does_not_run_cleanup(self):
        for name in ("restore-ovn-lab.sh", "restore-lab.sh"):
            for target in ("abc", "0", "11", "1+1"):
                with self.subTest(name=name, target=target):
                    self.log.write_text("", encoding="utf-8")
                    result, calls = self.run_script(name=name, target=target)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(calls, "")

    def test_ovs_preserves_unrelated_qos(self):
        result, calls = self.run_script(name="restore-lab.sh", target="3")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("--all destroy", calls)

    def test_ovs_ping_failure_returns_exit_1(self):
        result, _ = self.run_script(name="restore-lab.sh", target="3", MOCK_PING_FAIL="all")
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("Lab Restored", result.stdout)
        self.assertNotIn("Ready for", result.stdout)



if __name__ == "__main__":
    unittest.main(verbosity=2)
