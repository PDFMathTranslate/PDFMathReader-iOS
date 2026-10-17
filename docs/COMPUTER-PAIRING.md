# Pair a nearby computer

1. Connect the computer and iPhone or iPad to the same local network.
2. On the computer, enable **Auto-discovery** in **Settings → Experimental Features**.
3. Choose **Translation → Share Kernels with iPhone and iPad…** and enable sharing. Keep the computer awake and PDFMathReader open.
4. In iOS Settings, under the computer kernel section, tap **Find Nearby Computers** and allow Local Network access.
5. Select the computer, enter its pairing code, and tap **Check Connection**.

Manual address entry remains available when multicast discovery is unavailable, including on networks that isolate clients. Discovery only supplies the computer address; it does not pair automatically or broadcast the pairing code.

## Tailscale

Computers on the same tailnet are eligible alongside nearby devices. Connect Tailscale on both devices, keep kernel sharing enabled, and allow the connection in your tailnet access policy.

Discover the computer once over Wi-Fi, or enter its Tailscale IP or MagicDNS name and successfully check the connection. iOS remembers Tailscale endpoints learned from Bonjour or the authenticated computer response. Later, **Find Nearby Computers** also checks those remembered endpoints over Tailscale, including when you are away from the original Wi-Fi network. Discovery does not enumerate unknown tailnet devices and requires no Tailscale API key.

Remembered endpoints are limited to Tailscale IPv4 (`100.64.0.0/10`), IPv6 (`fd7a:115c:a1e0::/48`), and MagicDNS names under `.ts.net`. The search checks at most 16 remembered endpoints with a four-second TCP timeout and sends no credentials or documents. A reachable port makes the remembered computer selectable; **Check Connection** still authenticates PDFMathReader before translation. Use **Forget Remembered Computers** to clear the saved endpoints.

The desktop advertises `_pdfmathreader._tcp.` in `local.` only while both auto-discovery and kernel sharing are enabled. iOS resolves the advertised hostname and port and stops browsing when the user stops searching, selects a computer, leaves Settings, or backgrounds the app. The existing authenticated companion API handles connection checks and translation.

## Translation options from the computer

For Fast and computer-backed Precise translation, Settings and the reader’s More menu refresh the paired computer’s configured services and supported source/target languages every 15 seconds. **Automatic** uses the computer’s selected service; choosing a named service uses that service’s stored configuration and credentials on the computer. The iPhone’s Ultra Fast service and API key remain separate.

Language choices must be supported by both the kernel and the selected service. If a service is removed or its supported languages change, iOS returns to an available service and language; an unsupported explicit source returns to automatic detection. Computers running an older companion API retain the built-in service and language choices. The desktop companion update must be running to expose custom services and current language capabilities.

New desktop pairing codes contain eight characters, displayed as `ABCD-EFGH`. Existing 16-character codes remain valid until regenerated on the computer. iPhone and iPad accept either format, ignoring case, spaces, and separators.
