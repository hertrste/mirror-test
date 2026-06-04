Just a test repo for mirroring.

## libvirt mirror

This repository mirrors `https://github.com/cyberus-technology/libvirt.git` with a scheduled GitHub Actions workflow.

The workflow keeps this repository's `main` branch as the control branch and mirrors upstream refs into prefixed refs:

- upstream branches are pushed to `libvirt/<branch>`
- upstream tags are pushed to `libvirt/<tag>`

Keeping mirrored branches under the `libvirt/` prefix prevents upstream content from overwriting `.github/workflows/mirror-libvirt.yml` on `main`, so the scheduled mirror job remains in place.

GitHub does not allow the default Actions token to create or update workflow files from another repository. The mirror therefore strips `.github/workflows` from the mirrored branch and tag contents before pushing them.
