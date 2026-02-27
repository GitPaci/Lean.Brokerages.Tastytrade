#!/usr/bin/env bash
# =============================================================================
# setup-kanban.sh
# Sets up the "lab-agile-planning" GitHub repository and its Projects v2
# Kanban board ("Lab Agile Planning") with the required columns.
#
# Usage:
#   GITHUB_TOKEN=<token> bash setup-kanban.sh [--org <org>]
#
# Required env:
#   GITHUB_TOKEN   - GitHub Personal Access Token with scopes:
#                    repo, project, read:org
#
# Optional env / flags:
#   GITHUB_ORG     - GitHub org or user to own the repo (default: GitPaci)
#   --org <org>    - Same as GITHUB_ORG
#
# Column order produced:
#   1. Backlog         (kept from Kanban template default)
#   2. Icebox          (renamed from "Ready")
#   3. Product Backlog (new)
#   4. Sprint Backlogs (new)
#   5. In Progress     (kept from template)
#   6. Review/QA       (renamed from "In Review")
#   7. Done            (kept from template)
# =============================================================================
set -euo pipefail

# ── helpers ──────────────────────────────────────────────────────────────────
info()  { echo "[INFO]  $*"; }
ok()    { echo "[OK]    $*"; }
warn()  { echo "[WARN]  $*"; }
die()   { echo "[ERROR] $*" >&2; exit 1; }

require_token() {
  if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    die "GITHUB_TOKEN is not set. Export it before running this script:
    export GITHUB_TOKEN=ghp_xxxxxxxx
    bash setup-kanban.sh"
  fi
}

# GitHub REST API helper
gh_rest() {
  local method="$1" path="$2"
  shift 2
  curl -sSf \
    -X "$method" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com${path}" \
    "$@"
}

# GitHub GraphQL API helper
gh_graphql() {
  local query="$1"
  curl -sSf \
    -X POST \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Content-Type: application/json" \
    "https://api.github.com/graphql" \
    -d "$query"
}

# ── argument parsing ──────────────────────────────────────────────────────────
ORG="${GITHUB_ORG:-GitPaci}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --org) ORG="$2"; shift 2 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

REPO_NAME="lab-agile-planning"
PROJECT_TITLE="Lab Agile Planning"
README_CONTENT="# Lab Agile Planning

This repository contains the lab for agile planning.

## Overview

This repository was created as part of the **Get Set Up in GitHub** lab exercise.
It demonstrates how to create a GitHub repository with a Kanban board for
agile project management.

## Kanban Board Structure

The associated GitHub Project (**Lab Agile Planning**) uses the following columns:

| Column          | Purpose                                         |
|-----------------|-------------------------------------------------|
| Backlog         | All ideas and future work not yet prioritized   |
| Icebox          | Deprioritized items frozen for later            |
| Product Backlog | Prioritized items ready for sprint planning     |
| Sprint Backlogs | Items committed to the current sprint           |
| In Progress     | Work actively being worked on                   |
| Review/QA       | Work in review or quality assurance             |
| Done            | Completed work                                  |
"

# ── 1. Validate token ─────────────────────────────────────────────────────────
require_token
info "Token present – validating..."
USERNAME=$(gh_rest GET /user | python3 -c "import sys,json; print(json.load(sys.stdin)['login'])")
ok "Authenticated as: ${USERNAME}"

# ── 2. Create repository ──────────────────────────────────────────────────────
info "Checking if ${ORG}/${REPO_NAME} already exists..."
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${ORG}/${REPO_NAME}")

if [[ "$HTTP_STATUS" == "200" ]]; then
  warn "Repository ${ORG}/${REPO_NAME} already exists – skipping creation."
else
  info "Creating repository ${ORG}/${REPO_NAME}..."

  # Determine if ORG is an organisation or a user
  ORG_TYPE=$(gh_rest GET "/orgs/${ORG}" 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print('org')" 2>/dev/null \
    || echo "user")

  if [[ "$ORG_TYPE" == "org" ]]; then
    CREATE_URL="/orgs/${ORG}/repos"
  else
    CREATE_URL="/user/repos"
  fi

  gh_rest POST "$CREATE_URL" \
    -d "{
      \"name\": \"${REPO_NAME}\",
      \"description\": \"This repository contains the lab for agile planning\",
      \"private\": false,
      \"auto_init\": true,
      \"has_issues\": true,
      \"has_projects\": true
    }" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('  html_url:', d['html_url'])"

  ok "Repository created."

  # Add README
  info "Updating README.md..."
  BASE64_CONTENT=$(echo -n "$README_CONTENT" | base64 -w 0)
  CURRENT_SHA=$(gh_rest GET "/repos/${ORG}/${REPO_NAME}/contents/README.md" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('sha',''))" 2>/dev/null || echo "")

  if [[ -n "$CURRENT_SHA" ]]; then
    gh_rest PUT "/repos/${ORG}/${REPO_NAME}/contents/README.md" \
      -d "{\"message\":\"Update README with Kanban board documentation\",\"content\":\"${BASE64_CONTENT}\",\"sha\":\"${CURRENT_SHA}\"}" \
      > /dev/null
  fi
  ok "README updated."
fi

# ── 3. Get owner node ID (needed for Projects v2) ────────────────────────────
info "Fetching owner node ID for ${ORG}..."
OWNER_ID=$(gh_graphql \
  '{"query":"query { organization(login: \"'"${ORG}"'\") { id } }"}' \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
errors = data.get('errors')
if errors:
    org_id = None
else:
    org_id = data.get('data', {}).get('organization', {}).get('id')
print(org_id or '')
" 2>/dev/null)

if [[ -z "$OWNER_ID" ]]; then
  # Fall back: try as user
  OWNER_ID=$(gh_graphql \
    '{"query":"query { user(login: \"'"${ORG}"'\") { id } }"}' \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('data', {}).get('user', {}).get('id', ''))
")
fi

[[ -z "$OWNER_ID" ]] && die "Could not resolve node ID for owner '${ORG}'."
ok "Owner node ID: ${OWNER_ID}"

# ── 4. Check / create Project v2 ─────────────────────────────────────────────
info "Checking for existing project '${PROJECT_TITLE}'..."

EXISTING_PROJECT=$(gh_graphql \
  "{\"query\":\"query { organization(login: \\\"${ORG}\\\") { projectsV2(first: 20) { nodes { id title } } } }\"}" \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
nodes = (data.get('data') or {}).get('organization', {}).get('projectsV2', {}).get('nodes', [])
for n in nodes:
    if n['title'] == '${PROJECT_TITLE}':
        print(n['id'])
        break
" 2>/dev/null || true)

if [[ -n "$EXISTING_PROJECT" ]]; then
  warn "Project '${PROJECT_TITLE}' already exists (id: ${EXISTING_PROJECT}) – skipping creation."
  PROJECT_ID="$EXISTING_PROJECT"
else
  info "Creating project '${PROJECT_TITLE}'..."
  PROJECT_ID=$(gh_graphql \
    "{\"query\":\"mutation { createProjectV2(input: { ownerId: \\\"${OWNER_ID}\\\", title: \\\"${PROJECT_TITLE}\\\" }) { projectV2 { id } } }\"}" \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
errors = data.get('errors')
if errors:
    import sys; print('GraphQL errors:', errors, file=sys.stderr); sys.exit(1)
print(data['data']['createProjectV2']['projectV2']['id'])
")
  ok "Project created: ${PROJECT_ID}"
fi

# ── 5. Link repository to project ────────────────────────────────────────────
info "Linking repository to project..."
REPO_NODE_ID=$(gh_rest GET "/repos/${ORG}/${REPO_NAME}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['node_id'])")

gh_graphql \
  "{\"query\":\"mutation { linkProjectV2ToRepository(input: { projectId: \\\"${PROJECT_ID}\\\", repositoryId: \\\"${REPO_NODE_ID}\\\" }) { repository { name } } }\"}" \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
errors = data.get('errors')
if errors:
    # Already linked is OK
    if any('already' in str(e).lower() for e in errors):
        print('[WARN]  Repository already linked.')
    else:
        print('[WARN]  Link error (non-fatal):', errors)
else:
    print('[OK]    Repository linked to project.')
"

# ── 6. Get Status field ID + current options ──────────────────────────────────
info "Fetching Status field from project..."
FIELD_DATA=$(gh_graphql \
  "{\"query\":\"query { node(id: \\\"${PROJECT_ID}\\\") { ... on ProjectV2 { fields(first: 20) { nodes { ... on ProjectV2SingleSelectField { id name options { id name } } } } } } }\"}" \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
fields = (data.get('data') or {}).get('node', {}).get('fields', {}).get('nodes', [])
for f in fields:
    if f.get('name') == 'Status':
        import json
        print(json.dumps({'field_id': f['id'], 'options': f.get('options', [])}))
        break
")

[[ -z "$FIELD_DATA" ]] && die "Could not find 'Status' field on project."

FIELD_ID=$(echo "$FIELD_DATA" | python3 -c "import sys,json; print(json.load(sys.stdin)['field_id'])")
ok "Status field ID: ${FIELD_ID}"

# ── 7. Replace Status options with the 7 required columns ────────────────────
# GitHub Projects v2 updateProjectV2Field replaces all options atomically.
# Providing options without 'id' creates new ones; with 'id' updates existing.
# The order here determines the column order in the board.
info "Configuring Kanban columns..."

gh_graphql "$(python3 -c "
import json

columns = [
    ('Backlog',          'GRAY'),
    ('Icebox',           'BLUE'),
    ('Product Backlog',  'GREEN'),
    ('Sprint Backlogs',  'YELLOW'),
    ('In Progress',      'ORANGE'),
    ('Review/QA',        'PURPLE'),
    ('Done',             'RED'),
]

options_gql = ', '.join(
    '{name: \"%s\", description: \"\", color: %s}' % (name, color)
    for name, color in columns
)

mutation = '''mutation {
  updateProjectV2Field(input: {
    projectId: \"%s\",
    fieldId: \"%s\",
    singleSelectOptions: [%s]
  }) {
    projectV2Field {
      ... on ProjectV2SingleSelectField {
        id
        options { id name }
      }
    }
  }
}''' % ('${PROJECT_ID}', '${FIELD_ID}', options_gql)

print(json.dumps({'query': mutation}))
")" \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
errors = data.get('errors')
if errors:
    print('[ERROR] GraphQL errors:', errors, file=sys.stderr)
    sys.exit(1)
opts = (data.get('data') or {}).get('updateProjectV2Field', {}).get('projectV2Field', {}).get('options', [])
print('[OK]    Columns configured:')
for i, opt in enumerate(opts, 1):
    print(f'        {i}. {opt[\"name\"]}')
"

ok "Kanban board setup complete!"
echo ""
echo "View your board at: https://github.com/orgs/${ORG}/projects"
echo "Repository:         https://github.com/${ORG}/${REPO_NAME}"
