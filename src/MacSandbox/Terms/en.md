# Terms of Use — macSandbox for Windows

**Version 1.0** · Effective 2026-06-13

## Before you use this Software — please read

**Read these Terms in full before you build a Base Image or run the Software, and
decide on that basis whether to use it at all.** Using the Software is voluntary
and is entirely your decision.

You alone are responsible for complying with the licensing terms of any Guest OS
you run. A licensing violation is a matter between you and the operating-system
vendor and — depending on the nature and scale of the violation — can expose
**you** to financial cost and to civil liability, and, in cases of willful or
commercial-scale infringement, potentially to criminal liability. The Author
does not assume, share, or mitigate any of that risk on your behalf. **If you are
not prepared to take responsibility for your own licensing, do not use the
Software.**

---

## At a glance

> This summary is provided to draw your attention to key terms. **It is not part
> of the binding agreement and does not replace the full Terms below. If anything
> in this summary conflicts with the full text, the full Terms control.**

- **The Software includes no Windows.** No operating system, product key, or
  activation is provided — you must supply your own Windows installation medium.
  *(Section 3)*
- **Windows licensing is your responsibility — including your scenario.** You
  must hold a valid license for every Windows instance you run, and the *right*
  license depends on how you use it — accessing from a Mac, VDA, Windows 365 /
  Cloud PC, and commercial, enterprise, or shared-network use all carry their own
  requirements. Activation status — activated, unactivated, or watermarked — is
  **not** a substitute for a license. *(Section 4)*
- **Use it for lawful purposes.** Development, testing, security research, and
  evaluation are intended uses. The project does **not** support or condone
  circumventing any operating system's activation or licensing. *(Sections 5–6)*
- **Experimental software, provided "AS IS", with limited liability.** The
  Software is experimental and discards sandbox state when a session ends —
  expect data loss and keep your own backups. There is no warranty; the Author's
  liability is limited; and you agree to cover claims arising from your own use
  or your Windows licensing. *(Sections 9–11)*
- **The code's license is separate.** The Software is licensed under
  AGPL-3.0-or-later or a commercial license. These Terms govern your *use* and
  do **not** take away the freedoms granted by that license. *(Section 1)*
- **Independent project.** Not affiliated with or endorsed by Microsoft.
  *(Section 8)*

---

## 1. About these Terms

These Terms of Use ("**Terms**") govern your use of the **macSandbox for
Windows** application and its associated tooling and documentation (the
"**Software**"), made available by Nam Jung Hyun (rkttu) (the "**Author**").

These Terms are **separate from, and additional to, the Software license**:

- The Software's **source code** is licensed under the **GNU AGPL-3.0-or-later**
  (open-source edition) or under a **commercial license**, as described in
  `LICENSE`, `COMMERCIAL-LICENSE.md`, and `LICENSING.md`.
- These Terms govern **your conduct when using the Software** and the
  **allocation of responsibility** between you and the Author, in particular
  with respect to third-party operating-system licensing.

If any provision of these Terms conflicts with the rights granted to you under
the AGPL-3.0-or-later for the open-source edition, **the license controls and
the conflicting provision does not apply to the open-source edition.** Nothing
in these Terms is intended to restrict the freedoms granted by that license.

By installing, building a Base Image with, running, or otherwise using the
Software, **you acknowledge that you have read, understood, and agree to these
Terms.** If you do not agree, do not use the Software.

## 2. Definitions

- **"Software"** — the macSandbox for Windows application, its build tooling,
  scripts, and documentation, excluding bundled or linked third-party
  components.
- **"Guest OS"** — any operating system you choose to run inside the Software,
  including Microsoft Windows.
- **"Base Image"** — a Windows virtual-disk image you build using the Software
  from a Windows installation medium that **you** supply.
- **"You"** / **"your"** — the individual or entity using the Software.

## 3. No operating system is included

**The Software does not include, distribute, or provide any operating system,
product key, activation, license, or entitlement.** Specifically:

- The Software ships **no copy of Microsoft Windows**, no Windows product key,
  and no activation mechanism.
- To build a Base Image, **you must supply your own Windows installation medium
  (e.g., a Windows 11 ARM64 ISO obtained from Microsoft's official channels).**
- The Software does not activate Windows, does not assist in activating Windows,
  and does not bypass, emulate, or interfere with any Windows activation or
  licensing mechanism.

## 4. Your responsibility for Guest OS licensing

**You are solely responsible for holding a valid license for every Guest OS
instance you run, and for complying with all applicable license terms of that
Guest OS.** In particular:

- You must hold a valid Microsoft license appropriate to each Windows instance
  you build, run, or retain using the Software.
- **Activation status is not a substitute for a license.** Whether a Windows
  instance is activated, unactivated, or displays an evaluation watermark does
  not, by itself, establish that you are properly licensed. Microsoft's terms
  tie authorization to holding a valid license, not to activation state.
- Before each Base Image build, the Software presents a licensing checklist.
  **Your confirmation of that checklist is a representation that you have
  satisfied each item.** The Author does not verify, and cannot verify, your
  licensing status.

Your obligation extends to **scenario-specific entitlements.** The license type
required for a Windows instance depends on *how, where, and by whom* it is used,
and you are responsible for confirming that your entitlement actually covers your
specific scenario — including, without limitation:

- **Access from a non-Windows device.** The Software runs on macOS, so you are
  accessing a Windows instance from a non-Windows device. This scenario commonly
  requires per-user virtualization rights (for example, Windows Enterprise E3/E5
  or Microsoft 365 E3/E5) or a **Windows Virtual Desktop Access (VDA)**
  subscription, depending on your licensing program.
- **Windows 365 / Cloud PC and similar subscriptions.** A subscription such as
  Windows 365 licenses a Microsoft-hosted Cloud PC. **Do not assume it licenses
  a Base Image you build and run locally** with the Software; a locally run
  virtual machine is governed by the virtualization rights of your underlying
  Windows or Microsoft 365 licensing, not by a hosted Cloud PC subscription.
- **Commercial, organizational, and shared-network use.** Use outside a personal
  context — for example, on a public, corporate, enterprise, educational, or
  other shared network, or to provide access to other people — may be governed
  by Volume Licensing terms and may require different or additional entitlements
  (for example, VDA, qualifying Microsoft 365 plans, or Remote Desktop Services
  CALs). Consumer or OEM Windows licenses are generally not sufficient for such
  use.

**You are solely responsible for any license violation arising from these or any
other scenarios, whether or not you were aware of the applicable requirements.**
The examples above are illustrative, not exhaustive, and Microsoft's licensing
terms may change; you must consult Microsoft's current Product Terms and
licensing guidance, or a licensing specialist, for your own situation.

The Author makes no representation that any particular use of a Guest OS is
permitted by that operating system's vendor. **Determining and maintaining your
own compliance is your responsibility.**

## 5. Permitted use

The Software is a general-purpose virtualization tool intended for lawful uses,
including but not limited to: software development and testing; security research
and malware analysis in an isolated environment; evaluation of operating systems
and applications; accessibility and compatibility testing; continuous-integration
and automation workflows; and personal experimentation.

## 6. Acceptable use and non-endorsement

The Author does **not** authorize, endorse, or condone use of the Software to
infringe the rights of any third party. Without limiting the freedoms granted by
the applicable Software license, you understand that the project does not
provide, and you will not represent that the Author or the project sanctions,
support for:

- circumventing, disabling, emulating, or tampering with the activation,
  licensing, or technological protection measures of any Guest OS or other
  software;
- bundling, integrating, or distributing — together with or as an add-on to the
  Software — any tool whose purpose is to circumvent operating-system activation
  or licensing (for example, key generators or unauthorized activation servers);
  or
- using the Software to facilitate the unlicensed reproduction or distribution
  of any third party's software.

Requests to add such capabilities will be declined. This Section states the
Author's position and the scope of project support; for the open-source edition
it does not operate as a contractual restriction on the license freedoms.

## 7. Third-party components

The Software runs and links third-party components (for example, QEMU, EDK2
firmware, and FreeRDP/WinPR), each of which is provided under its own license.
Those licenses are described in `LICENSING.md`, `THIRD-PARTY-NOTICES.md`, and
`WRITTEN-OFFER.txt`, and your use of those components is governed by their
respective terms.

## 8. No affiliation; trademarks

macSandbox for Windows is an **independent project** and is **not affiliated
with, sponsored by, or endorsed by Microsoft Corporation.** Microsoft, Windows,
and related marks are trademarks of the Microsoft group of companies. All other
trademarks are the property of their respective owners. References to such marks
are nominative and for identification only.

## 9. Experimental software; disclaimer of warranties

The Software is provided on an **experimental, pre-release basis** for
development, testing, and evaluation. It may be incomplete or unstable, may
change or be discontinued at any time, and may behave unpredictably. **By design,
the Software discards sandbox state when a session ends, so you should expect
data loss. Do not keep anything inside the Software that you are not prepared to
lose, and back up your data independently.** You are solely responsible for any
loss of or damage to data, configuration, or work, and for any other consequence
arising from your use of the Software.

**The Software is provided "AS IS" and "AS AVAILABLE", without warranty of any
kind**, whether express, implied, statutory, or otherwise, including without
limitation any implied warranties of merchantability, fitness for a particular
purpose, title, and non-infringement. The Author does not warrant that the
Software will be uninterrupted, error-free, or secure. **You use the Software at
your own risk.**

## 10. Limitation of liability

To the maximum extent permitted by applicable law, **the Author will not be
liable for any indirect, incidental, special, consequential, exemplary, or
punitive damages, or for any loss of profits, data, or goodwill, or for any
third-party claims (including claims arising from your Guest OS licensing or your
use of any Guest OS), arising out of or relating to the Software or these Terms**,
regardless of the theory of liability and even if advised of the possibility of
such damages.

To the maximum extent permitted by applicable law, the Author's total aggregate
liability arising out of or relating to the Software or these Terms will not
exceed the amount you paid the Author, if any, for the Software during the twelve
months preceding the event giving rise to the claim — which, for the open-source
edition obtained at no charge, is zero. Liability that cannot be excluded or
limited under applicable law is not affected by this Section.

## 11. Indemnification

To the maximum extent permitted by applicable law, **you agree to indemnify and
hold the Author harmless from any claim, demand, loss, or expense (including
reasonable legal fees) arising out of (a) your use of the Software, (b) your
Guest OS licensing or your violation of any Guest OS's license terms, or (c) your
violation of these Terms or of any applicable law or third-party right.**

## 12. Changes to these Terms

The Author may revise these Terms. **Each revision is published with an
incremented version number and effective date.** When a materially revised
version is published, the Software may require you to review and re-acknowledge
the current Terms before further use. **Your continued use of the Software after
a revision takes effect constitutes acceptance of the revised Terms.** Prior
versions remain identified by their version number for recordkeeping.

## 13. Language editions, governing law, and disputes

These Terms are published in English, Korean, and Japanese editions. For users in
the Republic of Korea, the Korean edition applies; for users in Japan, the
Japanese edition applies; for all other users, this English edition applies. The
editions are intended to be substantively equivalent except for the
governing-law and forum provisions set out in this Section.

This English edition is governed by the laws of the Republic of Korea, without
regard to its conflict-of-laws principles. The Seoul Central District Court will
have exclusive jurisdiction as the court of first instance over any dispute
arising out of or relating to these Terms or the Software, except where mandatory
consumer-protection law of your place of residence grants you the right to bring
proceedings in, or requires application of the law of, another forum.

## 14. Severability

If any provision of these Terms is held unenforceable, that provision will be
limited or severed to the minimum extent necessary, and the remaining provisions
will remain in full force and effect.

## 15. Contact

Bug reports and feature requests are accepted only via the project's GitHub
Issues tracker: <https://github.com/yourtablecloth/macSandbox/issues>. There is
no e-mail support channel.

---

© 2026 Nam Jung Hyun (rkttu). macSandbox for Windows is an independent project and
is not affiliated with Microsoft.
