# Verificações da revisão técnica

Data: 15/10/2026. Consulte [o relatório de achados](../REVISAO-TECNICA.md).

## Workshop

Comandos executados na raiz do working directory:

```bash
npx --no-install antora --log-failure-level warn site.yml
git diff --check
python3 -B revisao-tecnica/candidato-labs/tests/test_lab_safety.py \
  --workshop-root "$PWD"
```

- Antora: retorno 0, sem avisos ou erros de geração.
- Verificação adicional dos destinos locais em `href` e `src`: **23 páginas,
  zero destinos ausentes**. Esse teste não valida o conteúdo de URLs externas
  nem a existência de todos os fragmentos `#âncora`.
- Whitespace: `git diff --check` sem apontamentos.
- Segurança dos candidatos: **37 testes locais aprovados**, com comandos
  administrativos simulados. Não equivalem a execução funcional nas VMs.
- Os blocos corrigidos de MTU, conntrack e consulta/compactação de bancos do
  módulo 13 passaram por `bash -n`; não foram executadas alterações de tuning
  ou compactação nas VMs. A seção de cenários possui nove blocos de consulta
  com sintaxe verificada e preserva as dez âncoras anteriores.
- A contagem de flows por tabela foi verificada com uma fixture sintética:
  seis flows contados, incluindo tabela 0 omitida; cabeçalho isolado não conta.
- Consulta ao GitHub: nenhuma PR ou issue aberta no repositório durante a revisão.

## Validação prática

As tentativas iniciais falharam com `No route to host`. O usuário ligou as VMs
durante a revisão, e o inventário somente leitura confirmou o acesso às três.
O cluster OCP continua indisponível. O estado encontrado contém configuração
persistida do OVN/OVS, mas não os namespaces temporários do laboratório.

Exemplo da consulta inicial, antes de qualquer alteração:

```bash
ssh root@ovsovnserver 'hostname; ip netns list; ovs-vsctl show; ovn-nbctl show'
```

Recorte literal da saída, com o restante omitido:

```text
ovsovnserver.example.local
    ovs_version: "3.6.2-1.fc44"
```

A listagem de namespaces não apresentou entradas. Já a NB continha `network1`,
`network2`, `external`, `router1` e regras NAT. Portanto, o teste precisa preservar
esse estado; não se trata de máquinas vazias.

### Resultados E2E

- **OVS:** ciclo completo dos alvos 2–10 e reexecuções 6/9/10 sem falhas.
  Os alvos 7–10 restauram a base do exercício 6; isso não equivale a reexecutar
  todos os passos manuais de mirroring, QoS e bonding desses exercícios.
- **OVN:** ciclo final dos alvos 1–10 e reexecuções 6/9/10, **13 etapas aprovadas**,
  sem correção manual durante essa rodada. Incluiu registros de chassis,
  conexão dos controllers, bindings, L2 local, L2 entre nós e roteamento L3.
- **DHCP:** captura de Discover, Offer, Request e ACK, lease `10.0.0.11`,
  endereço estático e hash de `/etc/resolv.conf` inalterados. O helper não aplica
  os parâmetros recebidos; não é um teste de configuração do guest por DHCP.
- **ACL:** TCP/22 e TCP/8080 permitidos; TCP/18080 bloqueado com listener
  comprovadamente ativo. O timeout desse teste negativo é o resultado esperado,
  não uma falha da suíte.
- **NAT:** SNAT observado nas duas sub-redes e DNAT com HTTP para `vm1`.
- **LB:** acesso direto aos três backends e respostas dos três pelo VIP. Não
  houve benchmark nem exigência de distribuição igual em poucas requisições.
- **Ferramentas:** coleta de `dump-flows --sort`, `dump-aggregate`,
  `connection-status`, `ct-zone-list`, Logical_Flow, logs, versões, traces de ACL
  e conntrack correlacionado a uma conexão real. Essa amostra não significa
  que todo comando ilustrativo dos módulos 11–13 foi executado.

Comando central da rodada final, com nomes/IPs passados pelo ambiente de teste,
não codificados no restore distribuído:

```bash
bash revisao-tecnica/candidato-labs/labs/standalone/restore-ovn-lab.sh "$alvo"
```

Trecho literal do último alvo 10:

```text
PASSOU_NAT: SNAT nas duas sub-redes e DNAT/HTTP para vm1.
PASSOU_LB: três backends diretos e os três observados pelo VIP; não é benchmark.
PASSOU_FUNCIONAL_ALVO=10
PASSOU_ETAPA=13 PASSOU_ALVO=10
```

Versões observadas, preservando a diferença entre identificação do binário e RPM:

```text
ovs-vswitchd (Open vSwitch) 3.6.2-1.fc44
ovn-controller 26.03.2-52.fc44
Open vSwitch Library 3.7.0
ovn-26.03.1-52.fc44.x86_64
```

Não foi investigada a origem dessa diferença de versão do OVN. Nenhum pacote
foi instalado ou atualizado pela auditoria.

### Falhas encontradas e corrigidas antes da rodada aprovada

- Verificador contava linhas em branco da saída `--bare` como chassis: passou
  a usar formato CSV e a conferir os três nomes esperados, preservando externos.
- Restaurações acumulavam linhas DHCP_Options: os novos registros recebem uma
  marca de propriedade e só são removidos se não tiverem consumidores externos.
  Os registros antigos sem marca foram preservados.
- Verificação de dependência Python em compute2 era desnecessária: os backends
  do exercício 9 ficam no central.
- O primeiro harness DHCP não conseguiu gravar PID/lease em `/tmp`; foi
  corrigido para estado exclusivo sob `/var/lib/dhclient/`, sem inferir uma
  causa de SELinux apenas pelo erro de permissão. A captura passou a usar
  modo imediato e teve quatro pacotes confirmados.

Os ciclos que falharam não foram contabilizados como aprovados. Seus logs foram
preservados junto com a rodada final limpa.

### Preservação e retorno das VMs

Foram preservados cinco bancos com `ovsdb-client backup`, schemas e configuração
de gestão/serviços/firewall antes dos testes. Ao restaurá-los, a comparação
normalizada com os escritores pausados apresentou:

```text
Open_vSwitch: 19/19 tabelas iguais; divergências=[]
OVN_Northbound: 39/39 tabelas iguais; divergências=[]
OVN_Southbound: 39/39 tabelas iguais; divergências=[]
```

O resultado Open_vSwitch foi obtido nos três nós. A comparação considera conteúdo
e referências, desconsiderando UUIDs de linha e campos efêmeros do schema. O
[restore OVSDB](https://www.openvswitch.org/support/dist-docs/ovsdb-client.1.html)
não promete preservar UUIDs nem estado efêmero.

Após retomar os serviços, a conferência passou nos três nós: IPs/rotas de gestão,
DNS, flags de serviços, sysctl e firewall runtime/permanente preservados;
namespaces do teste vazios e processos do teste ausentes. Não foram alterados o
servidor DNS, o hipervisor ou a bridge `virbr0`.

**O retorno não é bit a bit.** Índices de interfaces, MAC/link-local automático
do dispositivo Geneve, timestamps, ofports, tunnel keys, zonas CT e estados
dinâmicos de binding/up foram recalculados. O conntrack anterior não foi
preservado. A configuração encontrada já tinha inconsistências pós-boot e foi
devolvida como tal; não se afirma que o lab ficou montado e pronto para uso.

Evidências e backups privados ficam fora do repositório em
`/home/alolivei/Documents/MyLab/OVSvsOVN-audit-backups/2026-10-15/`.

### Identidade dos scripts testados

SHA-256 da rodada aprovada, usado para conferir a promoção sem alterações:

```text
restore-lab.sh       b267900201590d9617ebc650ce326b22503b6111c02ffc069977a541d2e5643d
restore-ovn-lab.sh   906f0c27e81eef34702853e6cd6cd48bd1998e826b6d527ff2206431d35f1a8b
lab-netns.sh         d29e1802e28c2de130a0c113ab1614a61789e9b65d588e1ba0ee1d9a823161f1
check-ovn-dhcp.sh    bb01d3a0fcfe90a2e5ce4512cf5b850a9e93dcb493416f2a8a8dc789589695df
```

## Red Hat One

- PPTX: **31 slides**, cinco tabelas nativas preservadas.
- Integridade do pacote: zero achados.
- Validação de layout: zero achados e zero avisos.
- Fonte codificada nos 412 usos de texto verificados: **Red Hat Display**.
- Reimportação dos bytes finais: aprovada, com 31 slides.
- Inspeção visual: realizada nos 19 slides alterados. A validação não incluiu
  execução no aplicativo Microsoft PowerPoint nem ensaio das demos no OCP.
- Os três scripts completos em `demo-setup.md` passaram por `bash -n`. Isso
  verifica sintaxe, não compatibilidade com um cluster.
- O gerador histórico foi executado para verificar a proteção: encerrou com
  retorno 1 antes de qualquer escrita e preservou o hash do PPTX existente.
- Links locais dos documentos revisados: nenhum destino ausente, considerando
  os arquivos originais de `evidence/` no diretório do RH1.

SHA-256 do PPTX corrigido:

```text
ead46500c45cd319a56e95b135f8beaf4c4129ea4cd89c253fdee09d02d23c46
```

## Limites

- As fontes oficiais e o código upstream sustentam as correções sem converter
  suporte upstream em garantia de suporte de produto.
- Não há benchmark novo, medição comparativa de desempenho ou certificação de
  todas as combinações de versões e hardware.
- Um teste standalone não valida os operadores, integrações e políticas de
  suporte específicos do RHOSP, RHOSO ou OCP.
- Não houve reboot durante os testes, provisionamento de VMs nem execução de
  teardown KVM/vSphere. Essas automações não receberam aprovação E2E.
- Nenhum commit, push, abertura de PR ou alteração no ambiente DNS foi solicitado.

## Cópias de entrega

As correções desta auditoria são sincronizadas entre o working directory
`/home/alolivei/Documents/MyLab/OVSvsOVN` e o repositório
`/home/alolivei/GitHub/myrepos/ovs-ovn-workshop`, com comparação de conteúdo antes
da escrita e SHA-256 depois da cópia. Alterações anteriores fora do escopo não
são sobrescritas. O diretório `revisao-tecnica/candidato-labs` contém também a
proposta KVM pendente; somente os quatro standalone identificados acima são
promovidos como automação validada.

O Red Hat One está em
`/home/alolivei/Documents/Presentation, KCS, Mojo and Blogs/Presentations/Red Hat One 2027`.
Seus oito arquivos autorais revisados foram atualizados com backup dos
originais, preservando os hashes dos 67 arquivos históricos de `evidence/`.
O HTML do workshop é regenerado em `www/` no working directory; não é necessário
commitar esse resultado gerado. Nenhum commit ou push foi realizado.
