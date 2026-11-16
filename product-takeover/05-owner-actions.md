# 05 — Owner Actions (plain-language checklist)

Everything the takeover team cannot do for you. Each item is small; together
they unblock revenue. Nothing here costs more than the Apple fee.

## Do these in order

### 1. Apple Developer Program — $99/year — *the single most important item*
1. Go to https://developer.apple.com/programs/ and enroll as an individual or
   organization (organization needs a D-U-N-S number; individual is faster).
2. Once enrolled: create a **Developer ID Application** certificate
   (Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application).
3. Export the certificate as a `.p12` file (Keychain Access → right-click the
   certificate → Export; set a password).
4. On the GitHub repo: Settings → Secrets and variables → Actions → add:
   - `MACOS_CERT_P12` = the .p12 file, base64-encoded
     (Terminal: `base64 -i cert.p12 | pbcopy`)
   - `MACOS_CERT_PASSWORD` = the password you set on export
   - `NOTARY_APPLE_ID` = your Apple ID email
   - `NOTARY_TEAM_ID` = your Team ID (developer.apple.com → Membership)
   - `NOTARY_PASSWORD` = an **app-specific password** (appleid.apple.com →
     Sign-In and Security → App-Specific Passwords)
5. Done. The pipeline is already wired to use these — and now **refuses to
   publish an unsigned release**, so the v0.90.0 Gatekeeper problem can never
   come back.

### 2. Push the takeover commits
Seven local commits (version truth, grammar retry, crash-loop guard, pipeline
hardening, URL centralization) are waiting on `main`, ahead of origin:
```
cd ~/Documents/deepseek-harness/default-workspace/kestrel
git push origin main
```
Then re-cut the release properly: bump VERSION, run `./scripts/release.sh`.

### 3. Move publishing to the Northlatch org
- Create/confirm the GitHub org, e.g. `Northlatch-Labs-LLC`.
- Transfer the kestrel repository (Settings → Danger Zone → Transfer).
  GitHub redirects old URLs automatically, and the app's repo slug is now a
  single constant — change `repositorySlug` in `Sources/App/AboutTab.swift`
  to the new org/name and updates follow.

### 4. Landing page
One page is enough to start: what it is, download button, tested-GPU list,
"Pro — coming" with an email field, enterprise contact. Any static host.

### 5. Decisions I need from you (one reply is enough)
- [ ] Pro tier price — roadmap suggests **$79/yr**. OK?
- [ ] Opt-in anonymous telemetry (install count, GPU model, DAU — no content,
      no identifiers) — allowed?  See `06-telemetry-design.md`.
- [ ] Copyright check: confirm every file in the repo is Northlatch's own
      (no copied-in code without attribution). Dual-licensing depends on it.

## What I already did (so you don't redo it)
Audits, defect register, roadmap, and seven verified code fixes — see
`README.md` and `04-revenue-roadmap.md` in this folder.
