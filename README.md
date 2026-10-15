# OVS & OVN Deep Dive - From Fundamentals to Troubleshooting

A comprehensive, hands-on workshop designed for Red Hat engineers who need to understand, operate, and troubleshoot Open vSwitch (OVS) and Open Virtual Network (OVN) across the Red Hat product portfolio.

## Published Site

This repository builds a workshop site using [Antora](https://antora.org/) with the [Red Hat Showroom](https://github.com/rhpds/showroom_template_nookbag) theme. The included workflow can publish the site to GitHub Pages when Pages is enabled for the repository.

**Live site:** *(URL available after GitHub Pages is enabled)*

## What This Workshop Covers

| Module | Topic |
|--------|-------|
| 00 | Introduction and workshop overview |
| 01 | Networking fundamentals (L2/L3, VLANs, tunneling) |
| 02 | OVS architecture and internals |
| 03 | OVS hands-on lab |
| 04 | OVN architecture and internals |
| 05 | OVN hands-on lab |
| 06 | OVS vs OVN - comparison |
| 07 | OVS/OVN in Red Hat OpenStack Platform (RHOSP) |
| 08 | OVS/OVN in Red Hat OpenStack Services on OpenShift (RHOSO) |
| 09 | OVN in Red Hat OpenShift Container Platform (OCP) |
| 10 | Traffic flows - tracing packets end-to-end |
| 11 | Management tooling |
| 12 | Troubleshooting methodology and tools |
| 13 | Limitations and known challenges |
| 14 | References and further reading |
| ts-01..06 | Real-world troubleshooting scenarios |

## Repository Structure

```
ovs-ovn-workshop/
├── content/                           # Antora content source
│   ├── antora.yml                     # Component descriptor
│   └── modules/ROOT/
│       ├── nav.adoc                   # Sidebar navigation
│       └── pages/                     # All workshop content (AsciiDoc)
│           ├── index.adoc             # Landing page
│           ├── 00-introduction.adoc   # Module 00: Introduction
│           ├── 01-*.adoc ... 14-*.adoc # Modules 01-14
│           ├── ts-01-*.adoc ... ts-06-*.adoc # Troubleshooting scenarios
│           └── slides.adoc            # Link to interactive slide deck
├── slides/                            # reveal.js interactive slide deck
│   └── index.html
├── labs/                              # Lab automation scripts
│   ├── standalone/                    # KVM/vSphere standalone labs
│   ├── rhosp/                         # RHOSP inspection scripts
│   ├── rhoso/                         # RHOSO inspection scripts
│   └── openshift/                     # OpenShift inspection scripts
├── diagrams/                          # Architecture diagrams source files
├── tests/                             # Local regression tests for lab helpers
├── site.yml                           # Antora playbook
├── package.json                       # Node.js dependencies (Antora)
└── .github/workflows/gh-pages.yml     # GitHub Pages CI/CD
```

## Local Preview

Build the complete site, including the interactive slide deck:

```bash
npm install
npm run build
# Open www/modules/index.html in your browser
```

Run `npm run build` again after editing the content or slides. To preview the published directory over HTTP:

```bash
python3 -m http.server 8080 --directory www
```

Open http://localhost:8080/modules/index.html. Stop the preview server with Ctrl+C.

For live preview of the Antora pages, you can also use Podman:

```bash
podman run --rm --name antora -v "$PWD:/antora:Z" -p 8080:8080 -i -t ghcr.io/juliaaano/antora-viewer
```

The container viewer rebuilds Antora pages when you edit `.adoc` or `.yml` files. Use `npm run build` when you need the complete output with the slide deck packaged under `www/slides/`.

## Local Checks

Run the lab helper regression tests without connecting to lab machines:

```bash
python3 -B tests/test_lab_safety.py
```

These tests use simulated system commands. They check script behavior and safety boundaries, but do not replace end-to-end testing on the target platform.

## Contributing

Found an error, want to add a scenario, or have a suggestion? Open an issue or submit a pull request. Contributions that improve clarity, fix technical inaccuracies, or add real-world troubleshooting examples are especially welcome.

## License

This material is internal to Red Hat and intended for Red Hat engineers. Do not distribute outside of Red Hat without authorization.
