
# Action Items

## Bugs

## Up next

- [ ] Need a cloud init YAML files for bringing up CaltechDATA on AWS as well as multipass VM
- [ ] Mirror the 2026-11-05 CaltechAUTHORS changes here, on `rsdoiel`, and test them on `data.caltechlibrary.dev` so they are in place
      before the v14 migration: nginx files linked from the checkout (not copied), a check after every pull (`nginx-deploy.bash verify`,
      `.githooks/post-merge`, a `verify_rdm_boot.bash` check), and `admin/safe_to_reboot.bash` + `admin/caltechdata_down.bash` installed
      with RDM. Details, sources and test steps: `~/WorkLab/agents/projects/caltechdata/notes/mirror-caltechauthors-nginx-links-and-reboot-scripts.md`.
