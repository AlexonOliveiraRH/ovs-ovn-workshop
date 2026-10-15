# Revisão de segurança dos laboratórios - validação parcial e promoção standalone

**Somente os quatro scripts standalone abaixo foram promovidos**, no escopo
da auditoria solicitada, após a cadeia E2E final sem falhas e o retorno verificado
à configuração original das três VMs. Isso não aprova provisionamento, teardown,
KVM, vSphere, OCP ou recuperação após reboot. Não houve instalação de pacotes,
commit ou publicação. A sincronização das cópias do workshop é registrada no
[relatório de validação](../validacao.md).

Os testes reais foram limitados aos objetos identificados do workshop em
`ovsovnserver`, `fedoraserver` e `fedoraclient`. Cinco backups OVSDB, inventários,
logs completos, capturas e comparações foram coletados em `/tmp/ovn-auditoria-JveIDa/e2e`
e arquivados fora do repositório em
`/home/alolivei/Documents/MyLab/OVSvsOVN-audit-backups/2026-10-15/e2e`.

## Conteúdo e isolamento

Os caminhos internos preservam a estrutura do workshop:

- `labs/standalone/restore-ovn-lab.sh`: propagação de erros remotos, retorno
  não zero em verificações negativas, validação de IPs/destinos SSH, limpeza
  nominal do lab, seis ACLs alinhadas ao exercício 7 e backends Python HTTP no
  exercício 9, com tamanho calculado em bytes, timeouts e preflight.
- `labs/standalone/restore-lab.sh`: limpeza restrita, preservação de QoS/queues
  não identificados como propriedade do lab e interrupção em falhas.
- `labs/standalone/lab-netns.sh`: helper novo; encerra processos dos namespaces
  indicados antes da exclusão e interrompe se ainda houver processos.
- `labs/standalone/check-ovn-dhcp.sh`: cópia exata do teste DORA evidenciado,
  com hook `/bin/true`, PID/lease exclusivos, captura e comparação de DNS/IP.
  Requer ferramentas já instaladas; não instala pacotes nem aplica a lease.
- `labs/standalone/kvm/teardown.sh`: remoção de VMs sem mascarar falhas de
  inventário, estado, parada, snapshots ou exclusão; preserva temporários
  globais cuja propriedade não foi comprovada.
- `labs/standalone/kvm/common.sh`: dependência inalterada, idêntica ao snapshot,
  incluída para manter a estrutura e permitir os testes isolados do KVM.
- `tests/test_lab_safety.py`: regressões locais com comandos administrativos
  simulados e teste do handler HTTP sem abrir sockets.

Foram promovidos via `apply_patch`: `restore-lab.sh`, `restore-ovn-lab.sh`,
`lab-netns.sh` e `check-ovn-dhcp.sh`, em `labs/standalone/`. Os bytes e SHA-256
ativos são idênticos aos candidatos executados. KVM e os testes novos permanecem
somente neste pacote; vSphere não foi alterado. O pacote KVM é proposta de
revisão isolada, não automação aprovada para uso.

## Baseline a preservar

Snapshot: `/tmp/ovn-auditoria-JveIDa/workshop-antes.tar`.

SHA-256: `6c25fae32793d49cc91d054241f7fe78b10cc464bf9997195700ae1e15a8c1d0`.

Durante a auditoria, a recomposição dos arquivos usou esse snapshot, não
`git HEAD`, para preservar mudanças antigas. Isso não é uma dependência dos
scripts de restore distribuídos. Três scripts diferiam do snapshot antes do empacotamento:
`restore-ovn-lab.sh`, `restore-lab.sh` e `kvm/teardown.sh`. Os demais scripts de
`labs/`, inclusive os de RHOSO já alterados anteriormente, coincidiam com ele.
Antes da promoção, o critério de isolamento foi zero diferenças de conteúdo e
nenhum arquivo novo em `labs/` ou `tests/` em relação ao snapshot.

Verificação após a restauração: **18 arquivos ativos de `labs/` idênticos byte
a byte ao snapshot, zero arquivos adicionais**. `diff --brief` retornou zero
para cada arquivo, e `diff -u` entre as listas de arquivos não mostrou diferenças.
Isso foi reconfirmado imediatamente antes da promoção. Depois dela, somente os
dois restores diferem do snapshot e os dois helpers foram adicionados. Os demais
16 arquivos de `labs/`, incluindo KVM/vSphere/RHOSO, continuam idênticos ao
snapshot. Os testes novos continuam ausentes do caminho ativo. As diferenças
antigas em relação ao Git foram preservadas; baseline zero antes da promoção
significa igualdade com o snapshot, não limpeza das alterações antigas no Git.

## Testes locais do candidato

Executado em 15/10/2026, a partir da raiz do workshop:

```bash
python3 -B revisao-tecnica/candidato-labs/tests/test_lab_safety.py \
  --workshop-root /home/alolivei/Documents/MyLab/OVSvsOVN
```

Resultado inicial, repetido depois de restaurar os caminhos ativos: **29 testes
aprovados, zero falhas**. `--workshop-root` fornece
somente a documentação usada para conferir as seis ACLs; os scripts testados
são os deste pacote, não os ativos. Os seis scripts do pacote também passaram
por `bash -n`. O harness usa PATH restrito e substitutos para SSH, namespaces,
serviços, OVN/OVS e libvirt. Não executa ações administrativas reais.

Para reproduzir as regressões no snapshot, sem modificar o workspace:

```bash
python3 -B revisao-tecnica/candidato-labs/tests/test_lab_safety.py \
  --workshop-root /home/alolivei/Documents/MyLab/OVSvsOVN \
  --snapshot /tmp/ovn-auditoria-JveIDa/workshop-antes.tar
```

Essa execução deve falhar: a suíte do candidato registrou 58 falhas de
asserção/subcenários no snapshot, sem erros do harness. Isso demonstra a
cobertura dos defeitos reproduzidos, não valida conectividade ou dataplane real.

Após as correções adicionais de dependência Python, verificação dos três
controllers/chassis/bindings, formato CSV, propriedade dos registros DHCP e
preservação de chassis externo na verificação: **37 testes locais aprovados**,
zero falhas, repetidos antes da promoção. Os logs RED/verde e os ciclos reais, inclusive
as tentativas que falharam, permanecem preservados no diretório de evidências.

## E2E real final e retorno

- **OVS:** alvos 2–10 e reexecuções 6/9/10, 12 etapas sem falhas, com o hash
  final. Os alvos 7–10 restauram somente a base 6; não representam execução
  integral dos recursos avançados desses exercícios. Evidência: `ovs-chain2.log`.
- **OVN:** alvos 1–10 e reexecuções 6/9/10, 13 etapas sem falhas nem correções
  manuais durante a cadeia final; retorno 0. Evidências:
  `resultado-cadeia-final.txt` e `ovn-final-etapa<N>-alvo<T>.log`.
- **DHCP:** helper candidato exato executado no alvo 4; quatro pacotes
  Discover/Offer/Request/ACK no mesmo intercâmbio, lease registrada, IP estático
  e SHA de `/etc/resolv.conf` preservados. Hook `/bin/true`; o cliente não aplica
  IP/DNS. Evidências: `ovn-final-etapa4-alvo4.log` e `dhcp-final-captura/`.
- **ACL/NAT/LB:** TCP/22 e TCP/8080 permitidos; TCP/18080 bloqueado com listener
  comprovado; SNAT das duas sub-redes e DNAT HTTP; três backends diretos e os
  três observados pelo VIP. O timeout do teste negativo de ACL e os avisos
  idempotentes `ALREADY_ENABLED` são esperados, não falhas da cadeia.
- **Módulos 11–13:** fluxos OpenFlow15, agregado, status dos três controllers,
  zonas/comandos disponíveis, contagem de 427 Logical_Flow no estado 10,
  traces com CT novo para permitir/bloquear e conntrack com HTTP estabelecido.
  Versões e caminhos de logs também registrados em `modulos11-13-final.log`
  e `modulos-final/`. Não houve benchmark nem reboot.
- **Retorno dos bancos:** `ovsdb-client restore`, sem `--force`, com escritores
  pausados. Comparação do conteúdo persistente normalizado: OVS 19/19 tabelas
  iguais em cada VM, NB 39/39 e SB 39/39, sem divergências. UUIDs das linhas e
  colunas efêmeras não são critérios de identidade.
- **Após retomar escritores:** configuração de gestão, IP/rotas, DNS, firewall
  runtime/permanente e arquivos, serviços, sysctl, nomes/flags/MTU das interfaces
  conferidos; nenhum namespace ou processo do teste restante. Evidências:
  `validacao-config-retorno.log`, `*-retomada-retorno.log` e diretórios
  `*-backup/` e `*-retorno/`.

O retorno **não é bit a bit e não recupera o estado CT anterior**. Os controllers
recalcularam timestamps, ofport, zonas CT, tunnel keys e referências derivadas
dos UUIDs; ifindex/MACs internos e o IPv6 link-local Geneve foram recriados.
`up`/binding de vm3 e portas de gateway foram reavaliados, e uma entrada dinâmica
MAC_Binding desapareceu. O baseline já não tinha namespaces e continha IDs e
bindings obsoletos; essas inconsistências preexistentes não foram reparadas.
Não foram forçados campos operacionais para produzir igualdade artificial.
As diferenças estão em `divergencias-operacionais.log` e `*-comparacao-final.log`;
as comparações pausadas estão em `*-comparacao-pausada.log`. Os dez registros
DHCP_Options originais voltaram pelo backup; não houve exclusão global seletiva
para ocultar registros das tentativas anteriores.

## SHA-256 promovidos

Conferidos por `cmp`, `sha256sum` e `bash -n` após a promoção; registro completo
em `promocao-sha256.log`. Correspondem aos hashes das execuções finais.

| Script em `labs/standalone/` | SHA-256 |
| --- | --- |
| `restore-lab.sh` | `b267900201590d9617ebc650ce326b22503b6111c02ffc069977a541d2e5643d` |
| `restore-ovn-lab.sh` | `906f0c27e81eef34702853e6cd6cd48bd1998e826b6d527ff2206431d35f1a8b` |
| `lab-netns.sh` | `d29e1802e28c2de130a0c113ab1614a61789e9b65d588e1ba0ee1d9a823161f1` |
| `check-ovn-dhcp.sh` | `bb01d3a0fcfe90a2e5ce4512cf5b850a9e93dcb493416f2a8a8dc789589695df` |

## Riscos e pendências

- **Validação parcial:** somente os quatro standalone promovidos foram
  liberados no escopo acima. Provisionamento, teardown, OCP e reboot não foram
  validados. Os mocks não substituem os testes reais desses outros componentes.
- **Laboratório exclusivo:** mesmo com exclusões nominais, os restores alteram
  serviços, conexões dos bancos e IDs de chassis. Não executar em hosts ou
  bancos compartilhados. Nomes iguais não comprovam propriedade dos recursos.
- **KVM, correção parcial:** descoberta/limpeza de redes, bridges e arquivos
  ainda possui tratamento permissivo de erros e seleção por prefixo. A correção
  de falso sucesso foi limitada à remoção de VMs; o teardown completo não está
  certificado. Snapshots, NVRAM e discos exigem validação real.
- **vSphere, pendente e inalterado:** `teardown.sh` ainda consulta o inventário
  global, perde o caminho completo ao usar `basename`, não alinha a seleção a
  `VM_FOLDER` e pode mascarar falhas. A exclusão de pastas exige revisão de
  propriedade/escopo. Não foi feito um refactor arriscado sem validação real.
- **Entradas do restore OVN:** os endereços aceitos são IPv4 decimal; IPv6 e
  opções SSH embutidas nas variáveis de destino são rejeitados deliberadamente.
- KVM/vSphere não foram promovidos nem executados. O pacote não deve ser
  sincronizado integralmente como automação aprovada; somente os quatro
  standalone atendem à autorização condicional de promoção desta rodada.

## Referências upstream

- [ovn-nb(5), ACLs e allow-related](https://www.ovn.org/support/dist-docs/ovn-nb.5.html).
- [ovn-sbctl(8), exclusão nominal de chassis](https://www.ovn.org/support/dist-docs/ovn-sbctl.8.html).
- [ip-netns(8), processos e remoção de namespaces](https://man7.org/linux/man-pages/man8/ip-netns.8.html).
- [Python, BaseHTTPRequestHandler](https://docs.python.org/3/library/http.server.html).
- [virsh, estado de domínios e undefine](https://libvirt.org/manpages/virsh.html).
- [ovsdb-client(1), backup/restore, UUIDs e colunas efêmeras](https://www.openvswitch.org/support/dist-docs/ovsdb-client.1.html).
- [ovn-trace(8), estados CT e limites da simulação](https://www.ovn.org/support/dist-docs/ovn-trace.8.html).
