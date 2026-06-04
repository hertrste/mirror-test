Just a test repo for mirroring.

## libvirt mirror

This repository mirrors `https://github.com/cyberus-technology/libvirt.git` with a scheduled GitHub Actions workflow.

The workflow keeps this repository's `main` branch as the control branch and mirrors upstream refs into prefixed refs:

- upstream branches are pushed to `libvirt/<branch>`
- upstream tags are pushed to `libvirt/<tag>`

Keeping mirrored branches under the `libvirt/` prefix prevents upstream content from overwriting `.github/workflows/mirror-libvirt.yml` on `main`, so the scheduled mirror job remains in place.

The workflow requires a repository secret named `MIRROR_TOKEN`. Use a token that can write repository contents and workflow files, for example a fine-grained token scoped to this repository with contents and workflows write access. This is required because the default Actions token cannot mirror upstream commits that contain `.github/workflows/*` files.
