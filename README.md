# Meridian Okta AD Lifecycle

**Okta as a third identity provider on a live hybrid Active Directory lab: agent, delegated authentication, JIT, import design, and a leaver process that actually reaches Okta**

[![Okta](https://img.shields.io/badge/Okta-Workforce%20Identity-007DC1?style=for-the-badge&logo=okta&logoColor=white)](https://www.okta.com/)
[![Active Directory](https://img.shields.io/badge/Active%20Directory-Windows%20Server%202022-0078D6?style=for-the-badge&logo=windows&logoColor=white)](#lab)
[![Okta AD Agent](https://img.shields.io/badge/Okta%20AD%20Agent-3.23.0-007DC1?style=for-the-badge&logo=okta&logoColor=white)](#phase-1-the-agent)
[![OAuth 2.0](https://img.shields.io/badge/OAuth%202.0-Private%20Key%20JWT-F78C40?style=for-the-badge&logo=openid&logoColor=white)](#phase-5-the-fix-the-leaver-tells-okta-directly)
[![PowerShell](https://img.shields.io/badge/PowerShell-7-5391FE?style=for-the-badge&logo=powershell&logoColor=white)](scripts/Revoke-OktaLeaverAccess.ps1)
[![Entra ID](https://img.shields.io/badge/Microsoft%20Entra%20ID-Hybrid-0078D4?style=for-the-badge&logo=microsoftazure&logoColor=white)](#lab)
[![Azure](https://img.shields.io/badge/Azure-Lab-0089D6?style=for-the-badge&logo=microsoftazure&logoColor=white)](#lab)
[![License](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)](LICENSE)

*Part 3 of the Meridian Financial Group lab. Part 1: [meridian-jml-engine](https://github.com/ZayLinux26/meridian-jml-engine). Part 2: [meridian-keycloak-ad-rbac](https://github.com/ZayLinux26/meridian-keycloak-ad-rbac)*

---

Most large companies run more than one identity provider. Entra ID came with Microsoft 365, Okta came with an acquisition or a SaaS rollout, and both read the same Active Directory. Each one gets its own integration project, and each project gets tested on day one: can people sign in? Almost nobody tests the question an auditor asks a year later: **when HR terminates someone, does every IdP find out?**

This project connects Okta to the Meridian Financial Group domain that Parts 1 and 2 built, then answers that question with evidence. The short version:

- The integration works the way the vendor documents it: AD agent, delegated authentication, JIT provisioning, scoped imports.
- A terminated employee **stayed Active in Okta** after the scheduled-style import ran. The import reported success and deactivated nobody. She was only caught when someone happened to look at her account, which means the console looks clean the moment anyone checks.
- A second terminated employee was **still signed in to Okta** after AD disabled her and Entra revoked her sessions.
- The fix is a containment step in the leaver process: a service app with a private key and a three-permission role clears the user's Okta sessions and deactivates them **in about a second**, with an audit record for every run.
- Taking the agent down showed one more thing worth knowing: Okta keeps a five-day credential cache for delegated authentication. That keeps people working during an outage, and it also means AD is not consulted for anyone in that cache. The containment step is what covers that window.

## Contents

1. [The enterprise problem](#the-enterprise-problem)
2. [What this project proves](#what-this-project-proves)
3. [Architecture](#architecture)
4. [Design decisions](#design-decisions)
5. [The build, phase by phase](#the-build-phase-by-phase) (reference section)
6. [Finding 1: the leaver gap](#finding-1-the-leaver-gap)
7. [Finding 2: the agent outage and the credential cache](#finding-2-the-agent-outage-and-the-credential-cache)
8. [What broke](#what-broke)
9. [Honest wall: lab vs. production](#honest-wall-lab-vs-production)
10. [Control mapping](#control-mapping)
11. [Questions this project answers](#questions-this-project-answers)
12. [Repository layout and running it](#repository-layout)

---

## The enterprise problem

A bank adding Okta to an existing Microsoft estate has to get four things right, and each one has a failure mode that only shows up later.

| Area | What has to be true | What goes wrong without care |
| --- | --- | --- |
| **Scope** | Only HR-anchored people reach the cloud IdP | Service accounts, Domain Admins and built-in accounts get imported, and now they can sign in to SaaS apps with no MFA owner |
| **Passwords** | Passwords stay in AD | A sync design copies password material to the cloud, and the security team blocks the rollout |
| **Joiners** | A new hire can sign in on day one | They wait for the next sync cycle and call the helpdesk |
| **Leavers** | Termination reaches every IdP fast | AD and Entra get the termination, Okta doesn't, and the person keeps their Okta session and every app account Okta provisions |

The last row is the one that becomes an audit finding, and it is invisible in normal operation because every component reports success.

## What this project proves

Every claim links to evidence from the live lab.

| Claim | Evidence |
| --- | --- |
| Only the five HR-anchored pilot users reach Okta. Admins, service accounts and Tier 0 groups stay out | [OU scope](screenshots/11-okta-user-ou-scope-pilot.png), [group scope](screenshots/12-okta-group-ou-scope.png), [import review](screenshots/20-okta-import-review-unconfirmed.png) |
| The agent runs as a dedicated account with no group memberships and no delegated rights | [Account hardened](screenshots/10-service-account-hardened.png) |
| Passwords never leave AD: Okta asks AD at sign-in through the agent | [Setting](screenshots/22-okta-delegated-auth-setting.png), [Elena signed in](screenshots/23-elena-okta-dashboard-delegated-auth.png), [log event](screenshots/24-system-log-delegated-auth-event.png) |
| An HR record becomes an Okta account with no admin in between | [JML joiner](screenshots/28-jml-day7-joiner-applied.png), [not in Okta](screenshots/29-okta-people-before-jit-no-daniel.png), [first sign-in](screenshots/30-daniel-first-signin-jit.png), [created by JIT](screenshots/31-okta-people-daniel-created-by-jit.png) |
| The import the scheduler runs left a terminated user Active | [0 deactivations](screenshots/39-import-monitoring-incremental-zero-deactivations.png) |
| She was deactivated only when someone looked her up | [Real-Time Sync event](screenshots/38-system-log-realtimesync-deactivation.png) |
| A terminated user stayed signed in to Okta after AD and Entra containment | [JML plan has no Okta step](screenshots/49-jml-day9-aisha-leaver-plan.png), [still signed in](screenshots/51-aisha-after-ad-disable-before-okta-containment.png) |
| The containment step cut her off, acting as a named service app | [Containment run](screenshots/52-okta-containment-aisha-real-run.png), [cut off](screenshots/53-aisha-cut-off-after-containment.png), [actor in the log](screenshots/55-system-log-actor-service-app.png) |
| Every containment run is audited, failures included, and re-running is safe | [Audit trail](screenshots/56-okta-containment-audit-trail.png) |
| The automation can touch only workforce users, and only three ways | [Custom role](screenshots/45-okta-custom-role-permissions.png), [scope by UPN](screenshots/43-okta-group-rule-upn-suffix.png), [assignment](screenshots/46-okta-service-app-admin-role.png) |
| With the agent down, new sign-ins fail and recent ones keep working | [Kevin fails](screenshots/57-kevin-signin-fails-agent-down.png), [existing session works](screenshots/57a-agent-down-existing-session-still-works.png), [agent back](screenshots/58-kevin-signin-works-agent-up.png) |

---

## Architecture

```mermaid
flowchart LR
    HR[(HR snapshot CSV)] --> JML[JML engine<br/>MFG-MGMT01]
    JML -- AD module --> AD[(Active Directory<br/>MFG-DC01<br/>meridianfg.internal)]
    JML -- Graph --> EN[(Microsoft Entra ID)]
    AD -- Cloud Sync --> EN
    AD -- LDAPS --> KC[Keycloak<br/>MFG-IDP01<br/>Part 2]
    AGENT[Okta AD Agent 3.23<br/>MFG-MGMT01<br/>outbound HTTPS only] -- LDAP reads,<br/>password checks --> AD
    AGENT == polls for work ==> OK[(Okta<br/>Workforce Identity)]
    JML -. leaver .-> CON[Revoke-OktaLeaverAccess.ps1<br/>private key JWT]
    CON -- clear sessions,<br/>deactivate --> OK
    U((Employee)) -- sign in --> OK
```

| Server | Role in this part | Address |
| --- | --- | --- |
| **MFG-DC01** | Windows Server 2022 **Core** domain controller for `meridianfg.internal`. Nothing installed on it for Okta | 10.20.0.4 |
| **MFG-MGMT01** | Windows Server 2022 member server: the Okta AD agent, the JML engine, the containment script and its private key | 10.20.0.5 |
| **MFG-IDP01** | Keycloak from Part 2. Not used here | 10.20.0.6 |

All three sit in one Azure VNet with RDP and SSH locked to a single admin IP. This is self-managed AD DS on Azure IaaS, which behaves the same as an on-premises deployment from the agent's point of view: the only network requirement is outbound HTTPS to Okta. There is no inbound port into the domain.

### Three identity providers, one directory

| | Entra ID (Part 1) | Keycloak (Part 2) | Okta (Part 3) |
| --- | --- | --- | --- |
| How it reads AD | Entra Cloud Sync agent | LDAPS bind | Okta AD agent |
| Where passwords are checked | Entra (password hash sync) | AD, live | AD, live (delegated auth) |
| Scope | `OU=Meridian` | `OU=Meridian`, `(employeeID=*)` | Finance, Compliance, HR pilot |
| How a leaver is contained | JML engine revokes Entra sessions | Revocation script (Part 2) | Containment script (this part) |
| Leaver trap found | OU move out of sync scope soft-deleted the user | Cached user and live session survived termination | Incremental import missed the leaver; session survived termination |

Three products, one failure pattern. When the leaver process moves an account or relies on the next sync, every IdP that reads AD needs its own answer to "how do I find out right now?"

---

## Design decisions

**1. A pilot wave, not the whole domain.** Okta was scoped to Finance, Compliance and HR (five people). That is how real Okta rollouts start, and the trial's ten-user cap made it a requirement anyway. The pilot was chosen from a fresh inventory of HR-anchored users, not from documentation ([01](screenshots/01-ad-preflight-inventory.png)).

**2. Only HR-anchored people reach the IdP.** Every OU outside the three department OUs stayed unchecked: domain controllers, `Service Identities`, `Service Accounts`, the built-in `Users` container (Administrator, krbtgt), computers. An IdP that imports a service account gives that account a password-based sign-in to whatever apps get assigned to "Everyone."

**3. Groups from `OU=Groups` only.** That OU holds the `GG-MFG-*` role groups and `DL-MFG-App-*` app groups from Parts 1 and 2. Tier 0 groups such as Domain Admins live in the built-in containers and never reach Okta, so nobody can accidentally assign an app to them or build a policy on them in the cloud.

**4. UPN as the Okta username, and the match rule.** `mail` was blank for every user ([13](screenshots/13-upn-vs-mail-check.png)), so the default "Email matches" rule would have matched nothing. The Okta username is the UPN, which Part 1 already set to the routable `@isaiahherard26gmail.onmicrosoft.com` suffix, and matching is on the username. One sign-in name across Windows, Entra and Okta, and audit logs from all three join on the same value.

**5. Profile attributes chosen, not bulk-imported.** Only `employeeID`, `department`, `title`, `manager`, `employeeType` and the office came across. Every extra attribute is personal data living in a second system.

**6. One-way provisioning.** AD sources Okta users and their profiles are read-only in Okta. The To App direction (Okta writing to AD) stays off. Two systems able to change the same identity means the audit question "who changed this account?" stops having one answer.

**7. Manual review on the first import.** Auto-confirm and auto-activate were left off so a human checked the five proposed users against the expected population before anyone became active ([20](screenshots/20-okta-import-review-unconfirmed.png)). A scoping mistake gets caught on a review screen instead of after activation emails go out.

**8. The automation identity can't touch the admins.** The containment service app holds a custom role with three user permissions, scoped to a group whose membership comes from the UPN suffix. Details in [Phase 5](#phase-5-the-fix-the-leaver-tells-okta-directly).

---

## The build, phase by phase

This is the reference section: what each step did, why, and what it looked like.

### Phase 0: pre-flight

**Inventory before design.** Twelve HR-anchored users, ten enabled, two in `Disabled Users` from earlier parts, and domain functional level 2016, which matters because Okta can only enforce AD password history at that level or above.

| AD inventory | Agent account test |
| --- | --- |
| [![Inventory](screenshots/01-ad-preflight-inventory.png)](screenshots/01-ad-preflight-inventory.png) | [![gMSA](screenshots/02-gmsa-okta-created-test-true.png)](screenshots/02-gmsa-okta-created-test-true.png) |

**The plan was a gMSA.** A group Managed Service Account has a 120-character password that AD rotates every 30 days and no human ever knows. Okta's docs support it for the agent. The gMSA was created in `OU=Service Identities` (outside the Cloud Sync scope), with only MFG-MGMT01 allowed to retrieve its password. How that went is in [What broke](#what-broke).

### Phase 1: the agent

The agent lives on MFG-MGMT01, not the domain controller. The DC is Tier 0 and runs Server Core with nothing extra installed, same as Parts 1 and 2. Okta recommends a member server too.

**Service account, final state:** `svc-okta-bootstrap`, a plain domain user in `OU=Service Identities` with:

- a 32-character random password generated on the server, never displayed, stored only in the vault
- **no group memberships** beyond Domain Users and **no delegated rights**: reading users, groups and OUs and checking passwords need nothing more
- password set not to expire, because an expired password silently kills the agent (compensating controls in the [honest wall](#honest-wall-lab-vs-production))

| Agent running | Account hardened | Agent live in Okta |
| --- | --- | --- |
| [![Running](screenshots/09-okta-agent-restored-bootstrap-account.png)](screenshots/09-okta-agent-restored-bootstrap-account.png) | [![Hardened](screenshots/10-service-account-hardened.png)](screenshots/10-service-account-hardened.png) | [![Agents](screenshots/16-okta-agents-tab.png)](screenshots/16-okta-agents-tab.png) |

**Pre-Windows 2000 warning.** The installer warned that the service account is not a member of *Pre-Windows 2000 Compatible Access* and incremental imports might fail. I didn't add it. `Authenticated Users` is already a member of that group, so every domain account inherits its read access, and the installer only checks direct membership ([05](screenshots/05-pre-win2000-false-positive.png)). Incremental imports later ran without errors. Granting a legacy domain-wide read group because an installer warned about it is how service accounts end up over-privileged.

The same check turned up something nobody added on purpose: **MFG-MGMT01's computer account is a direct member** of that group. It is logged as an open drift item.

### Phase 2: import design

| User OU scope | Group OU scope | Username decision |
| --- | --- | --- |
| [![Users](screenshots/11-okta-user-ou-scope-pilot.png)](screenshots/11-okta-user-ou-scope-pilot.png) | [![Groups](screenshots/12-okta-group-ou-scope.png)](screenshots/12-okta-group-ou-scope.png) | [![UPN](screenshots/13-upn-vs-mail-check.png)](screenshots/13-upn-vs-mail-check.png) |
| **Attributes** | **Defaults before** | **Matching after** |
| [![Attributes](screenshots/14-okta-profile-attributes-selected.png)](screenshots/14-okta-profile-attributes-selected.png) | [![Defaults](screenshots/17-okta-import-matching-rules.png)](screenshots/17-okta-import-matching-rules.png) | [![Matching](screenshots/18-okta-import-matching-rules.png)](screenshots/18-okta-import-matching-rules.png) |

Okta's defaults after the wizard were a blank "Custom" username format and **Email matches** as the match rule. Both would have broken this import: one gives users no usable login, the other matches on an attribute that is empty for everyone.

**First import:** a full import, reviewed by hand. Five users, all proposed as **New Okta user** because nothing in the tenant matched them, which is correct for a new tenant. In a migration where people already had Okta accounts, you want "Exact match" here instead, and a match against an admin account would be the red flag. Okta's default mapping filled each user's email from the UPN, so the blank `mail` attribute didn't cause errors.

| Import summary | Review before confirming | Pilot active |
| --- | --- | --- |
| [![Summary](screenshots/19-okta-first-full-import-summary.png)](screenshots/19-okta-first-full-import-summary.png) | [![Review](screenshots/20-okta-import-review-unconfirmed.png)](screenshots/20-okta-import-review-unconfirmed.png) | [![People](screenshots/21-okta-people-pilot-active.png)](screenshots/21-okta-people-pilot-active.png) |

### Phase 3: delegated authentication and JIT

**Delegated authentication** was on by default for the integration. To prove it, Elena's password was reset **in AD only**, then she signed in to Okta with it. Okta forwarded the password to the agent, the agent asked AD, AD said yes. Okta holds no copy of her AD password, AD's lockout and password policy still apply, and an AD reset takes effect in Okta immediately.

| Setting | Elena signed in | Log |
| --- | --- | --- |
| [![Setting](screenshots/22-okta-delegated-auth-setting.png)](screenshots/22-okta-delegated-auth-setting.png) | [![Elena](screenshots/23-elena-okta-dashboard-delegated-auth.png)](screenshots/23-elena-okta-dashboard-delegated-auth.png) | [![Log](screenshots/24-system-log-delegated-auth-event.png)](screenshots/24-system-log-delegated-auth-event.png) |

**JIT provisioning** closes the gap between an AD account existing and the next import. The test ran the whole chain:

1. HR file gets a new Compliance hire, Daniel Reyes, employee ID **100014**
2. The Part 1 JML engine plans and creates `dreyes` in `OU=Compliance` with his birthright groups
3. Okta has never heard of him
4. Daniel signs in to Okta. Okta checks his password with AD, sees he's in a scoped OU, and creates his account on the spot

Nobody opened the Okta console.

| Joiner plan | Applied | Not in Okta |
| --- | --- | --- |
| [![Plan](screenshots/27-jml-day7-joiner-plan.png)](screenshots/27-jml-day7-joiner-plan.png) | [![Applied](screenshots/28-jml-day7-joiner-applied.png)](screenshots/28-jml-day7-joiner-applied.png) | [![Before](screenshots/29-okta-people-before-jit-no-daniel.png)](screenshots/29-okta-people-before-jit-no-daniel.png) |
| **First sign-in** | **Created by JIT** | **Log** |
| [![Signin](screenshots/30-daniel-first-signin-jit.png)](screenshots/30-daniel-first-signin-jit.png) | [![Created](screenshots/31-okta-people-daniel-created-by-jit.png)](screenshots/31-okta-people-daniel-created-by-jit.png) | [![Log](screenshots/32-system-log-jit-create-event.png)](screenshots/32-system-log-jit-create-event.png) |

Getting there took two tries, and the first try is a good example of the engine doing its job: see [What broke](#what-broke) #6.

### Phase 4: the leaver gap

Covered in full in [Finding 1](#finding-1-the-leaver-gap).

### Phase 5: the fix, the leaver tells Okta directly

The containment step does two things, in this order:

1. **Clear every Okta session and every OAuth token** issued to apps on the user's behalf (`DELETE /api/v1/users/{id}/sessions?oauthTokens=true`)
2. **Deactivate the user** (`POST /api/v1/users/{id}/lifecycle/deactivate`), which also triggers deprovisioning in every app Okta provisions to

Containment first, cleanup second, the same order the JML engine uses for AD and Entra.

**How it authenticates.** An Okta API token would have been the quick route. It is a long-lived secret tied to whichever admin created it. Instead:

| Control | Setting |
| --- | --- |
| Identity | `MFG-JML-Leaver-Containment`, an OAuth API Services app with its own entry in the audit log |
| Credential | **Private key JWT**. The RSA key pair was generated **on MFG-MGMT01**; only the public key (JWK, KID `mfg-jml-2026-10`) went to Okta. The private key never passed through a browser or a clipboard |
| Key storage | `C:\Lab\okta-jml-key`, inheritance removed, access for Administrators and SYSTEM only |
| Tokens | Client credentials grant, 5-minute signed assertion, short-lived access token |
| Scopes | `okta.users.read`, `okta.users.manage` |
| Admin role | Custom role **MFG JML Leaver Containment** with three permissions: view users, edit lifecycle states, clear sessions |
| Resource set | Users in `MFG-Workforce-AD-Sourced` only |

| Public key only | Scopes | Custom role | Assignment |
| --- | --- | --- | --- |
| [![Key](screenshots/41-okta-service-app-public-key-only.png)](screenshots/41-okta-service-app-public-key-only.png) | [![Scopes](screenshots/42-okta-service-app-scopes.png)](screenshots/42-okta-service-app-scopes.png) | [![Role](screenshots/45-okta-custom-role-permissions.png)](screenshots/45-okta-custom-role-permissions.png) | [![Assign](screenshots/46-okta-service-app-admin-role.png)](screenshots/46-okta-service-app-admin-role.png) |

**The scoping trap.** The obvious way to limit the role is "only users in our AD groups." It would have failed on exactly the people it exists for. The JML leaver strips every AD group from a leaver before anything else, so by the time containment runs, the leaver is in none of those groups and a group-scoped role refuses to act on them.

The resource set uses an Okta group whose membership comes from the **login name** instead:

```
String.stringContains(user.login, "@isaiahherard26gmail.onmicrosoft.com")
```

Every AD-sourced workforce user matches, leavers included. The super admin (`admin@isaiahherard.com`) doesn't, so the automation can never deactivate the people who would respond if its key leaked.

| Group rule | Members: five workforce users, no admin |
| --- | --- |
| [![Rule](screenshots/43-okta-group-rule-upn-suffix.png)](screenshots/43-okta-group-rule-upn-suffix.png) | [![Members](screenshots/44-okta-workforce-group-members.png)](screenshots/44-okta-workforce-group-members.png) |

The automation's own app was deliberately left **out** of the resource set. With the current permissions it would do nothing, but if someone later added app permissions to this role, the automation could edit its own app and keys. An identity that can change its own credentials is the classic escalation path.

**Blast radius if the key leaks:** an attacker could sign workforce users out and deactivate them. Disruptive, but no data access, no MFA changes, no app assignments and no path to the admins.

The script is [`scripts/Revoke-OktaLeaverAccess.ps1`](scripts/Revoke-OktaLeaverAccess.ps1) and the key generation is [`scripts/New-OktaJmlKeyPair.ps1`](scripts/New-OktaJmlKeyPair.ps1).

### Phase 6: the agent outage

Covered in [Finding 2](#finding-2-the-agent-outage-and-the-credential-cache).

---

## Finding 1: the leaver gap

### Test 1: does the import catch a leaver?

Rachel Stein, AML Analyst in Compliance, was terminated through the HR file. The JML engine disabled her, stripped her groups and moved her to `OU=Disabled Users`, which is outside Okta's import scope. Then I ran the same kind of import Okta's scheduler runs.

| Before: Active | Leaver applied | Incremental import |
| --- | --- | --- |
| [![Before](screenshots/33-okta-rachel-active-before-leaver.png)](screenshots/33-okta-rachel-active-before-leaver.png) | [![Leaver](screenshots/35-jml-day8-rachel-leaver-applied.png)](screenshots/35-jml-day8-rachel-leaver-applied.png) | [![Import](screenshots/36-okta-incremental-import-after-leaver.png)](screenshots/36-okta-incremental-import-after-leaver.png) |

The import completed successfully and **deactivated nobody** ([39](screenshots/39-import-monitoring-incremental-zero-deactivations.png)). Rachel showed **Active**. Okta documents this behavior: scheduled AD imports are incremental, they only query the selected OUs for objects changed since the last run, and a user moved to an unselected OU is never seen. Only a full import deactivates users who left scope.

A minute later she showed **Deactivated**. I assumed the import had caught up. The System Log said otherwise:

| Field | Value |
| --- | --- |
| EventType | `app.realtimesync.import.details.delete_user` |
| DisplayMessage | RealTimeSync for user delete was successful |
| Actor | Okta System |

**The import never caught her. Real-Time Sync did.** When an AD-sourced user is looked up (an admin opening them in the console, or the user trying to sign in), Okta asks AD through the agent for their current state. The agent couldn't find her in the scoped OUs, so Okta deactivated her. The lookup came from my admin session.

[![Real-Time Sync event](screenshots/38-system-log-realtimesync-deactivation.png)](screenshots/38-system-log-realtimesync-deactivation.png)

**Why this is worse than a plain gap:** the act of investigating fixes the evidence. An auditor sampling terminated users in the Okta console sees "Deactivated" and closes the test. With nobody looking and no sign-in attempt, she stays Active, and so does every app account Okta provisions for her.

**The cheap fix didn't take.** The obvious remedy is to add `OU=Disabled Users` to the import scope so leavers stay visible. After setup, the Integration settings page only offered OUs on the path to the originally selected ones. `Disabled Users` was not selectable, even after a page reload and an agent restart, although AD showed the OU exists and `Authenticated Users` can read it ([40](screenshots/40-okta-ou-tree-disabled-users-not-offered.png)).

### Test 2: does the termination end a live Okta session?

Aisha Grant in HR signed in to Okta and left the tab open. HR terminated her. The JML plan shows the problem before anything runs:

[![JML plan for Aisha](screenshots/49-jml-day9-aisha-leaver-plan.png)](screenshots/49-jml-day9-aisha-leaver-plan.png)

Ten actions: disable in AD and revoke Entra sessions (marked `*` as containment), then groups, OU move and the terminated stamp. **Nothing touches Okta**, because Okta isn't in the engine's world.

After the plan was applied, Aisha's Okta tab refreshed **still signed in** ([51](screenshots/51-aisha-after-ad-disable-before-okta-containment.png)). AD disabled, Entra revoked, engine reported success, and her Okta dashboard and every app tile on it still worked.

### The fix, and the retest

```powershell
./scripts/Revoke-OktaLeaverAccess.ps1 -UserPrincipalName agrant@isaiahherard26gmail.onmicrosoft.com
```

| Containment run | Her tab after refresh | Actor in the System Log |
| --- | --- | --- |
| [![Run](screenshots/52-okta-containment-aisha-real-run.png)](screenshots/52-okta-containment-aisha-real-run.png) | [![Cut off](screenshots/53-aisha-cut-off-after-containment.png)](screenshots/53-aisha-cut-off-after-containment.png) | [![Actor](screenshots/55-system-log-actor-service-app.png)](screenshots/55-system-log-actor-service-app.png) |

The deactivation event in the System Log names the actor as **MFG-JML-Leaver-Containment**, a `PublicClientAppEntity`, with a `PowerShell/7.6.6` user agent from MFG-MGMT01's address. Not an admin, not "Okta System." An examiner can tie the termination to a named automation identity, a time, an HR record and a JML run ID.

The audit file tells the whole story, failures included:

| UTC | User | Status before | Sessions cleared | Deactivated | Result |
| --- | --- | --- | --- | --- | --- |
| 20:10:13 | esokolova | | False | False | Failed (dry run, bad client ID) |
| 20:10:20 | esokolova | | False | False | Failed (dry run, bad client ID) |
| 20:11:27 | esokolova | ACTIVE | False | False | WhatIf |
| 20:22:44 | agrant | ACTIVE | **True** | **True** | **Contained** |
| 20:25:13 | agrant | DEPROVISIONED | True | False | Contained (re-run, nothing left to deactivate) |

[![Audit trail](screenshots/56-okta-containment-audit-trail.png)](screenshots/56-okta-containment-audit-trail.png)

The live run took **1.3 seconds**. The second run shows the step is safe to repeat: it found her already deactivated, cleared sessions again and skipped the rest. That is the same idempotency rule as the JML engine, and it means an operator retrying at 2 AM can't make things worse.

| Layer | Before | After |
| --- | --- | --- |
| Active Directory | Disabled, groups stripped | Same |
| Entra ID | Sessions revoked | Same |
| Okta account | **Active until someone looked her up** | Deactivated by the leaver, about a second after AD |
| Okta browser session | **Still signed in** | Ended |
| Apps Okta provisions to | **Still active** | Deprovisioning triggered by the deactivation |

---

## Finding 2: the agent outage and the credential cache

Okta's setup screen recommends at least two agents. With delegated authentication, every password sign-in depends on an agent reaching AD, and this lab has one. So I stopped it.

| Kevin: new sign-in, agent down | Elena: existing session, agent down | Kevin: agent back |
| --- | --- | --- |
| [![Fails](screenshots/57-kevin-signin-fails-agent-down.png)](screenshots/57-kevin-signin-fails-agent-down.png) | [![Works](screenshots/57a-agent-down-existing-session-still-works.png)](screenshots/57a-agent-down-existing-session-still-works.png) | [![Back](screenshots/58-kevin-signin-works-agent-up.png)](screenshots/58-kevin-signin-works-agent-up.png) |

- **Kevin Walsh**, who had never signed in to Okta, **failed** to sign in while the agent was down ([System Log](screenshots/57b-system-log-kevin-delauth-failure.png)) and succeeded once it came back.
- **Elena** stayed signed in, which was expected: an outage doesn't end existing sessions.
- Then Elena **signed out and signed back in with her password** in a private window, with the agent confirmed stopped, and **got in**.

That last one is documented Okta behavior. With delegated authentication on, Okta keeps its own hash of a user's last successful password sign-in (not AD's hash) and accepts it for up to **five days** if no agent can reach AD.

What that means in practice:

- **Resilience:** an agent outage is gentler than "nobody can sign in." People who used a password in the last five days keep working. New hires and anyone who hasn't signed in recently are locked out.
- **Security:** during an outage, **AD is not being asked**. A person terminated while the agent is down is disabled in AD but can still sign in to Okta with a cached password for days, unless Okta itself deactivates them. Okta's community answers also confirm the old password keeps working if it was changed in AD while AD was unreachable.

This is where the two findings meet. The containment step deactivates the user **in Okta through the API**, which doesn't depend on the agent. It closes the window the cache opens.

Okta also published a 2024 advisory affecting this cache path, where under certain conditions (delegated auth on, no MFA, agent unreachable) cached logins could skip a fresh check. MFA was the mitigation, and this lab doesn't have workforce MFA yet. It's in the honest wall.

---

## What broke

**1. The installer can't install the agent as a gMSA.** Okta's docs say to enter the gMSA name and leave the password blank. The installer registered the agent with Okta, then failed creating the Windows service and rolled back. The setup log had the reason:

```
Okta Active Directory Service | ...\OktaAgentService.exe | MERIDIAN\gmsa-okta$ | 1057
```

Error 1057 is `ERROR_INVALID_SERVICE_ACCOUNT`. The gMSA itself was fine (`Test-ADServiceAccount` returned True). The most likely cause is how the installer passes the empty password to Windows; I can't prove that from outside the installer. Most of the installer log's "error" lines were dialog conditions evaluating to false (`...|0`); the real failure was a single line. ([04](screenshots/04-okta-agent-install-failed-gmsa.png))

**2. The agent can't be moved to a gMSA after install either.** I installed with a temporary account, then switched the service to the gMSA in the Services console. Windows logged on as the gMSA fine, then the agent stopped:

```
Could not load encrypted configuration settings ... Probably, the configuration file was
encrypted by another user. ---> CryptographicException: Key not valid for use in specified state.
```

The installer encrypts the agent's config with DPAPI under the install account, so only that account can read it. Okta's support article confirms the service account name can't be changed in place; it takes a reinstall. With the installer refusing the gMSA and the config refusing a switch, I went back to the temporary account and hardened it. The account kept its `svc-okta-bootstrap` name, since renaming it means another reinstall. ([07](screenshots/07-service-logon-changed-to-gmsa.png), [08](screenshots/08-agent-started-then-stopped-as-gmsa.png))

**3. A failed install still leaves state behind.** The first install wrote `OktaAgentService.exe.instances.config` before rolling back. I removed the folder (keeping the logs) before reinstalling so the new install didn't reuse a dead registration.

**4. Admin sign-in failed from the server, and the log said why in one look.** The System Log showed the actor as `admin@isaiahhherard.com` (three h's) and the target user as `(id: unknown)`: Edge had saved a typo. The password was never checked, so there was no lockout risk. ([03](screenshots/03-okta-system-log-signin-failure.png))

**5. Wrong section, wrong direction.** The first attempt to set the username format landed in the To App section, which controls Okta writing users into AD. Cancelled without saving. Okta has a separate Edit button per section, and the URL fragment (`#tab-general/import-n-mastering`) is the quickest way to know you're on the right one.

**6. A duplicate employee ID in the HR file.** The first day 7 feed had employee `100013` on two lines. The JML engine rejected both rows and planned zero actions instead of guessing. `100013` turned out to be Grace Liu, a future hire with a January 2027 start date, so she exists in HR but not in AD (the pre-hire window from Part 1). I had picked a taken ID. In production, IDs come from the HRIS and are never invented by IT. ([26](screenshots/26-jml-duplicate-employeeid-rejected.png))

**7. My prediction about the leaver was half wrong.** I predicted the incremental import would leave Rachel Active. It did, but she flipped to Deactivated a minute later and I nearly credited the import. The System Log showed Real-Time Sync. Lesson: read the event type before writing the finding.

**8. `invalid_client` on the first token request.** I transcribed the client ID from a screenshot. It contains `Ozl`; I typed `OzI`. Capital I and lowercase l look the same in Okta's font. Both failed attempts are in the audit trail, which is the point of auditing failures. IDs get copied, never retyped. ([47a](screenshots/47a-okta-token-invalid-client.png))

**9. "Agent down" but Elena got in, twice.** The first time, Safari still held her Okta session, so no password was checked at all (the log event was a token grant, not an authentication). The second time was a real password sign-in, answered from Okta's five-day credential cache. Neither was the result I expected, and the second turned into Finding 2.

**10. The Okta trial won't take a personal email.** Signup requires a business domain. I registered a domain on Cloudflare and used free Email Routing to forward to my inbox, with a test message confirmed before signup, because Okta doesn't resend the activation email.

---

## Honest wall: lab vs. production

| Lab | Production |
| --- | --- |
| One agent on MFG-MGMT01 | Two or more agents on separate servers in separate failure domains, same version. Finding 2 is the business case |
| Agent account is a vaulted 32-character password set never to expire (gMSA blocked, see What broke #1 and #2) | Same compensating controls plus a GPO denying interactive and RDP logon, and a scheduled rotation, which for this agent means a reinstall |
| Account name still says `bootstrap` | Named for its role from the start |
| MFG-MGMT01 hosts the agent, the JML engine, the containment key and the enterprise CA from Part 2 | The CA alone makes it Tier 0. Split the CA onto a dedicated, hardened host |
| Containment is a companion script run after the JML leaver | A step inside the engine's leaver plan, with containment status and exit code 3 when it fails, like the Entra revocation in Part 1 |
| DPoP turned off on the service app | DPoP binds access tokens to the client's key. Turn it on once the client can produce DPoP proofs |
| `Disabled Users` couldn't be added to import scope after setup | Decide leaver OU scope before running the setup wizard, or move leavers within an already-scoped OU |
| No scheduled imports, no periodic full import | Scheduled incremental imports plus a regular full import as a reconciliation backstop, with Import Monitoring counts reviewed |
| No MFA for workforce users | MFA (phishing-resistant where possible) on every Okta sign-in. It is also the mitigation for the 2024 credential cache advisory |
| Five-day credential cache left at default | Documented as a known tolerance in the leaver control, with the API containment as the covering control |
| Test passwords set by an admin in PowerShell | Ticketed helpdesk action; the user sets their own password |
| Containment audit in a local JSONL file | Shipped to the SIEM with retention, alongside the Okta System Log |
| `MFG-MGMT01` is a direct member of Pre-Windows 2000 Compatible Access, origin unknown | Traced and removed if nothing depends on it |
| Daniel Reyes still `PendingSync` in Entra Cloud Sync | Cloud Sync job health monitored and alerted, as Part 1 found it can stall |

---

## Control mapping

| Framework | Control | How this project addresses it |
| --- | --- | --- |
| **PCI DSS v4.0** | 7.2.1, 7.2.2 | Access scoped to HR-anchored users in defined OUs; non-human and privileged accounts kept out of the IdP |
| | 8.2.5 | Terminated users lose Okta access, including live sessions, in about a second after AD |
| | 8.2.6 | Inactive accounts: leavers no longer depend on an import or a lookup to be deactivated |
| | 8.3.1 | Authentication verified against the directory of record at sign-in (delegated auth) |
| | 8.6.1 to 8.6.3 | Agent and automation accounts are dedicated, least privilege, non-interactive, credentials vaulted or key-based |
| **SOX ITGC** | Logical access: terminations | Termination evidence ties HR record, JML run ID, Okta actor and timestamp; failures audited |
| **NIST SP 800-53** | AC-2, AC-2(3) | Account management driven from HR; disabled accounts lose IdP access |
| | AC-2(4) | Automated audit records for every containment run |
| | AC-6, AC-6(10) | Custom role with three permissions; automation cannot act on administrators |
| | AC-12 | Sessions terminated on termination |
| | IA-2, IA-5 | Delegated authentication against AD; key-based authentication for the automation |
| | AU-2, AU-3 | Okta System Log events plus local audit records with user, actor, time and outcome |
| | CP-2 | Agent single point of failure identified and tested; HA documented |
| **ISO/IEC 27001:2022** | A.5.15, A.5.16, A.5.18 | Access control, identity management and access rights from one source of truth |
| | A.8.2 | Privileged access: automation scoped away from admins |
| | A.8.5 | Secure authentication: no passwords in the cloud, no API tokens in automation |
| | A.8.15 | Logging of authentication and lifecycle events |

---

## Questions this project answers

**Does Okta store our AD passwords?** Not as AD stores them. With delegated authentication, Okta sends each sign-in to AD through the agent. It does keep its own hash of the last successful password sign-in for up to five days, as an outage fallback. That cache is worth knowing about, because during an outage it means AD isn't consulted.

**Why put the agent on a member server and not the DC?** The DC is Tier 0. Every extra service and logon on it is attack surface. The agent only needs to read AD and check passwords, which a member server can do.

**Why didn't you add the service account to Pre-Windows 2000 Compatible Access?** `Authenticated Users` was already a member, so the account had the access. The installer only checks direct membership. Imports worked without it.

**Why UPN and not email or SAM account name?** `mail` was blank for every user, and SAM names aren't email-shaped. The UPN is always populated, unique in the forest, and already the sign-in name for Windows and Entra.

**Why did the scheduled import miss a terminated user?** Scheduled imports are incremental. They only look in the selected OUs for objects changed since the last run. The leaver process moved her to an OU Okta doesn't look in, so from Okta's view she just stopped existing.

**If the import misses leavers, why did she end up deactivated anyway?** Real-Time Sync. Looking her up in the console made Okta check her against AD on the spot. It only happens when someone looks or the user tries to sign in.

**Why not just run a full import every night?** That helps, and production should have it as a backstop. It still leaves up to a day where a leaver is active, and it does nothing about a session that's already open. The containment step is immediate and ends the session.

**Why a private key instead of an API token?** An API token is a long-lived secret tied to the admin who made it. A private key that never leaves the server, exchanged for short-lived access tokens under a scoped role, gives the automation its own identity and a small blast radius.

**Why scope the role by UPN suffix instead of by group?** The leaver loses every group before containment runs. A group-scoped role would refuse to act on the one person it exists for.

**What happens if the agent goes down?** People with an open Okta session keep working. People who signed in with a password in the last five days can sign in again from the cache. Everyone else, including new hires, can't sign in until an agent is back. Run at least two.

---

## Repository layout

```
scripts/
  New-OktaJmlKeyPair.ps1        generates the service app key pair on the server; prints the public JWK
  Revoke-OktaLeaverAccess.ps1   leaver containment: clear sessions and tokens, deactivate, audit
screenshots/               evidence from the live lab
```

The AD agent, OU scope, import settings, delegated authentication, JIT, the service app, the custom role, the resource set and the group rule were configured in the Okta Admin Console, and every setting is documented above with the reason for it.

### Running the containment step

```powershell
# One time, on the server that will run it: generate the key and upload the printed JWK to the service app
./scripts/New-OktaJmlKeyPair.ps1

# Dry run: real token, real lookup, no changes
./scripts/Revoke-OktaLeaverAccess.ps1 -UserPrincipalName user@domain -WhatIf

# Live, right after the JML leaver
./scripts/Revoke-OktaLeaverAccess.ps1 -UserPrincipalName user@domain
```

Exit codes follow the JML engine: `0` contained, `3` containment failed (page someone, a leaver may still have access).

### Resuming the lab after the VMs were stopped

1. Start **MFG-DC01** first (it's everyone's DNS), then **MFG-MGMT01**.
2. The Okta agent reconnects on its own. Check **Directory Integrations → meridianfg.internal → Agents** for Operational.

## Roadmap

- Fold Okta containment into the JML engine's leaver plan as a containment step with its own status and exit code
- Second Okta AD agent on a separate server
- Scheduled incremental imports plus a periodic full import, with Import Monitoring counts alerted
- Workforce MFA in Okta, then rerun the agent-outage test
- Okta as SAML IdP into Entra, with Entra PIM for just-in-time admin access

## License

MIT. See [LICENSE](LICENSE).
