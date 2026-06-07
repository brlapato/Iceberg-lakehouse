# Keycloak Setup Guide

This guide covers what to create in your Keycloak instance before deploying the RBAC-enabled lakehouse stack.

## 1. Create a Realm

Create a realm named `lakehouse` (or whatever you set in `keycloak/config.yaml`).

In the Keycloak Admin Console:  
**Master** → **Create Realm** → Name: `lakehouse` → **Create**

## 2. Create the Trino Client

Trino uses OAuth2/OIDC for browser-based login and the Web UI.

1. Go to **Clients** → **Create client**
2. **Client ID:** `trino`
3. **Client type:** OpenID Connect
4. Enable **Client authentication** (makes it confidential)
5. **Valid redirect URIs:** `https://localhost:8443/oauth2/callback`  
   (add any other hosts/IPs if accessing Trino from other machines)
6. **Web origins:** `https://localhost:8443`
7. Save → go to **Credentials** tab → copy the **Client secret**

### Add Groups Claim (Required for Ranger group policies)

So Trino forwards Keycloak group membership to Ranger:

1. Go to your `trino` client → **Client scopes** → click `trino-dedicated`
2. **Add mapper** → **By configuration** → **Group Membership**
3. **Name:** `groups`  
   **Token Claim Name:** `groups`  
   **Full group path:** OFF  
   **Add to ID token:** ON  
   **Add to access token:** ON  
4. Save

## 3. Create the OpenMetadata Client

OpenMetadata uses OIDC SSO for the web UI.

1. Go to **Clients** → **Create client**
2. **Client ID:** `openmetadata`
3. **Client type:** OpenID Connect
4. Enable **Client authentication**
5. **Valid redirect URIs:** `http://localhost:8585/callback`
6. **Web origins:** `http://localhost:8585`
7. Save → **Credentials** tab → copy the **Client secret**

## 4. Create Groups (Optional but Recommended)

Groups map to Ranger policies for bulk access control.

Go to **Groups** → **Create group**:

| Group name | Suggested use |
|---|---|
| `lakehouse-admins` | Full access to all Trino catalogs |
| `lakehouse-analysts` | Read-only access to `lakehouse` catalog |

Assign users to groups via **Users** → select user → **Groups** tab.

## 5. Create Users

Go to **Users** → **Create user**:

- Set **Username** (this becomes the `preferred_username` claim — what Trino and Ranger see)
- Set a password under **Credentials** tab
- Assign groups under **Groups** tab

The Ranger `admin-all` policy grants the user named `admin` full access.  
Create a Keycloak user with username `admin` and assign it the `lakehouse-admins` group.

## 6. Run the Secrets Script

After creating the clients above, run:

```bash
bash scripts/keycloak-secrets.sh
```

This prompts for the client secrets you copied in steps 2 and 3, and creates the required K8s secrets.

## 7. Update Stack Config

Edit `config/lakehouse-config.yaml` — set `KEYCLOAK_URL`, `KEYCLOAK_REALM`, and
the client IDs to match your Keycloak instance, then propagate:

```bash
make keycloak-config
```

This recomputes the derived fields (`KEYCLOAK_ISSUER_URL`, `KEYCLOAK_JWKS_URL`),
patches OpenMetadata and Trino values files, and applies the ConfigMap to the cluster.

## Ranger UserSync (Next Step — Not Automated)

By default Ranger creates user records on first policy check (when a Keycloak-authenticated user first queries Trino). For proactive user/group sync from Keycloak:

- Deploy Ranger UserSync with Keycloak's REST API endpoint
- Or configure Keycloak as an LDAP provider and point Ranger UserSync at the LDAP endpoint

See [Ranger UserSync documentation](https://ranger.apache.org/usersync-guide.html) for details.
