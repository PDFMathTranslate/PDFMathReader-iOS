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
