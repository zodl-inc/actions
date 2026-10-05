# zodl-inc/actions

Shared GitHub Actions of zodl-inc.

## aws-secrets

Reads a repository's GitHub Actions secrets and variables from AWS and exports
them as environment variables for the next steps of the job. Secrets are
masked in logs.

Values live in AWS, one place per repo, managed in
[zodl-inc/github-config](https://github.com/zodl-inc/github-config) (private):

| | Secrets (Secrets Manager) | Variables (SSM Parameter Store) |
|---|---|---|
| repo | `/github/<repo>/actions` (JSON), or `/github/<repo>/<NAME>` for `per_secret` repos | `/github/<repo>/<NAME>` |
| environment | `/github/<repo>/env/<env>` (JSON) | `/github/<repo>/env/<env>/<NAME>` |
| org | `/github/_org/<NAME>` | `/github/_org/<NAME>` |

The action assumes the repo's role `github-ci/<repo>` (or
`github-ci/<repo>--<env>` for an environment) with the job's OIDC token.
Those roles can only read their own repo's values and the org values visible
to the repo. The AWS credentials stay inside the action and are not exported
to later steps.

### Usage

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write          # required
    steps:
      - uses: zodl-inc/actions/aws-secrets@v1
        with:
          secrets: |
            ZODL_QA
            KEYSTORE=UPLOAD_KEYSTORE_BASE_64_SOLANA
          vars: |
            AWS_REGION
      - run: ./build.sh        # uses $ZODL_QA, $KEYSTORE, $AWS_REGION
```

Environment secrets (the job must run in that environment, which is what
protects them):

```yaml
  release:
    environment: Deployment
    permissions:
      id-token: write
    steps:
      - uses: zodl-inc/actions/aws-secrets@v1
        with:
          environment: Deployment
          secrets: GOOGLE_PLAY_PUBLISHER_API_KEY
```

| Input | Meaning |
|---|---|
| `secrets` | One per line: `NAME`, or `ENV_NAME=NAME`. Looked up in the environment, then the repo, then the org. |
| `vars` | Same syntax, for variables. |
| `environment` | The job's environment, for environment secrets. |
| `aws-region` | Default `us-east-1`. |

The step fails if a name is not found or not readable, listing which.

### Migrating a workflow

1. Add `id-token: write` to the job's permissions.
2. Add the step before the first step that needs the values.
3. Replace `${{ secrets.NAME }}` with `${{ env.NAME }}` (or `$NAME` in shell)
   and `${{ vars.NAME }}` likewise.

GitHub keeps receiving every secret and variable from github-config while
workflows move over, so a repo can migrate one workflow at a time.

### Notes

- Needs `aws`, `jq`, `curl`, `openssl` on the runner (present on GitHub-hosted
  runners).
- Fork pull requests get no OIDC token, so they cannot read anything. Do not
  call this from `pull_request_target` workflows that run fork code.
- Adding or changing a value: see github-config `README.md`
  (`scripts/secret-set.py`).

### Versions

Use `@v1`. Tags `v*` cannot be moved or deleted except by repository admins,
who move `v1` to each compatible release.
