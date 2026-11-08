# Security policy

Cælōcord Blue Moon Edition is an initial public release. Security review is ongoing; there is no security certification, guaranteed response time, or bug bounty.

## Report privately

**Do not file public issues for security vulnerabilities or publish exploit details.**

- Prefer GitHub **Security → Report a vulnerability** if private vulnerability reporting is enabled for this repository.
- Otherwise contact the licensor using the address in [LICENSE.md](./LICENSE.md). Do not send real recordings, passwords, or other private files without a safe, agreed method.

Include the version, affected feature, impact, Windows version, and minimal reproduction steps using test data. Do not test against anyone else's device or information.

## Security boundaries

- The application uses a Go launcher, Windows PowerShell/WPF, and FFmpeg. **Only run software from sources you trust.**
- Recordings are saved locally, but **not encrypted by Cælōcord**. Operating-system permissions, backups, and synchronization software may affect their confidentiality.
- The default EXE may offer to download FFmpeg from a third-party site with user consent. Review [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md).
- Windows capture exclusion is not a guarantee against every capture method. Test it before relying on it.
- No built-in account system or cloud upload is provided. This does not mean Windows, FFmpeg hosts, or third-party tools never use network services.
- Security checks cannot prove the absence of every vulnerability or secret. The distributed EXE is unsigned and was not tested in a real Windows session during packaging.
- A GitHub Actions release workflow exists. Review its dependencies and downloaded components before publishing releases.

See [README.md](./README.md), [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md), and [LICENSE.md](./LICENSE.md).
