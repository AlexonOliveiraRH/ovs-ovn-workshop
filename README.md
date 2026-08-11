# OVS & OVN Deep Dive - From Fundamentals to Troubleshooting

A comprehensive, hands-on workshop designed for Red Hat engineers who need to understand, operate, and troubleshoot Open vSwitch (OVS) and Open Virtual Network (OVN) across the Red Hat product portfolio.

## Published Site

This workshop is published via GitHub Pages using [Antora](https://antora.org/) with the [Red Hat Showroom](https://github.com/rhpds/showroom_template_nookbag) theme.

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
├── site.yml                           # Antora playbook
├── package.json                       # Node.js dependencies (Antora)
└── .github/workflows/gh-pages.yml     # GitHub Pages CI/CD
```

## Local Preview

Run the site locally with Podman:

```bash
podman run --rm --name antora -v $PWD:/antora:Z -p 8080:8080 -i -t ghcr.io/juliaaano/antora-viewer
```

Then open http://localhost:8080 in your browser. The site rebuilds automatically when you edit `.adoc` or `.yml` files.

Alternatively, build with npm:

```bash
npm install
npx antora site.yml
# Open www/modules/index.html in a browser
```

## Contributing

Found an error, want to add a scenario, or have a suggestion? Open an issue or submit a pull request. Contributions that improve clarity, fix technical inaccuracies, or add real-world troubleshooting examples are especially welcome.

## License

This material is internal to Red Hat and intended for Red Hat engineers. Do not distribute outside of Red Hat without authorization.
