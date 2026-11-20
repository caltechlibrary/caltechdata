
# Action Items

## Bugs

## Up next

- [ ] Need a cloud init YAML files for bringing up CaltechDATA on AWS as well as multipass VM
- [ ] Port the CaltechAUTHORS Multipass trusted-hosts fix into `cloud-init-multipass.yaml` (found 2026-11-20 on the CaltechTHESIS VM, which
      lacked it). `invenio.cfg` has `TRUSTED_HOSTS = ["data.caltech.edu"]`, so opening a Multipass VM by its IP gets 400 Bad Request, and
      Multipass changes the address at will. caltechauthors (`rsdoiel` branch, commit `6e58a4c`, local and unpushed) has
      `set_trusted_hosts.bash` and `rdm-trusted-hosts.service`: the script rewrites `INVENIO_TRUSTED_HOSTS` in the app's `.env` to localhost,
      127.0.0.1, 0.0.0.0, the production name, the VM's hostname and its current global addresses, and the service runs it at every boot
      before `rdm.service`, `rdm_rest.service` and `rdm_celery.service`; the setup script also runs it once after writing `.env`. Change the
      `.env` path and production name, and wait for the caltechauthors branch to settle before copying so the two stay identical. Related
      Multipass boot fixes in the same branch: `rdm-block-datacite.service` (`/etc/hosts` is rewritten at boot) and no listing of the `staff`
      and `www-data` groups. Also check this repo's `templates/` overrides for stale full-file copies of RDM templates (CaltechTHESIS's
      `records/detail.html` included a template v14 removed, so every record page returned 500).
- [x] (done 2026-11-09, live on `data.caltechlibrary.dev`; R8.7 certbot reissue still open) Mirror the 2026-11-05 CaltechAUTHORS changes here, on `rsdoiel`, and test them on `data.caltechlibrary.dev` so they are in place
      before the v14 migration: nginx files linked from the checkout (not copied), a check after every pull (`nginx-deploy.bash verify`,
      `.githooks/post-merge`, a `verify_rdm_boot.bash` check), and `admin/safe_to_reboot.bash` + `admin/caltechdata_down.bash` installed
      with RDM. Details, sources and test steps: `~/WorkLab/agents/projects/caltechdata/notes/mirror-caltechauthors-nginx-links-and-reboot-scripts.md`.
