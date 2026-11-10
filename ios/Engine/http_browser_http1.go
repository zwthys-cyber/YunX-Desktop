// SPDX-License-Identifier: AGPL-3.0-only
package httpclient

import (
    "context"
    "crypto/tls"
    "net"
    "strings"

    "github.com/imroc/req/v3"
    utls "github.com/refraction-networking/utls"
)

// req.EnableForceHTTP1 changes the wire transport, but its browser ClientHello
// still advertises h2. Keep the browser preset and restrict its actual ALPN.
func yunxBrowserHTTP1(client *req.Client, browser Browser) {
    hello := utls.HelloChrome_120
    switch browser {
    case BrowserFirefox: hello = utls.HelloFirefox_120
    case BrowserSafari: hello = utls.HelloSafari_16_0
    }
    client.SetTLSHandshake(func(ctx context.Context, address string, plain net.Conn) (net.Conn, *tls.ConnectionState, error) {
        // req passes tlsHost() (usually just a hostname); custom callers may
        // provide host:port. Handle both, including bracketed/raw IPv6.
        host := address
        if value, _, err := net.SplitHostPort(address); err == nil { host = value }
        host = strings.TrimSuffix(strings.TrimPrefix(host, "["), "]")
        source := client.GetTLSClientConfig()
        if source.ServerName != "" { host = source.ServerName }
        config := &utls.Config{
            ServerName: host, RootCAs: source.RootCAs, InsecureSkipVerify: source.InsecureSkipVerify,
            NextProtos: []string{"http/1.1"}, MinVersion: source.MinVersion, MaxVersion: source.MaxVersion,
            Rand: source.Rand, Time: source.Time, CipherSuites: source.CipherSuites,
            SessionTicketsDisabled: source.SessionTicketsDisabled,
            DynamicRecordSizingDisabled: source.DynamicRecordSizingDisabled,
        }
        // Generate an independent preset for every handshake: extensions and
        // key shares must never be mutated concurrently by other connections.
        spec, err := utls.UTLSIdToSpec(hello)
        if err != nil { return nil, nil, err }
        extensions := make([]utls.TLSExtension, 0, len(spec.Extensions))
        for _, extension := range spec.Extensions {
            switch value := extension.(type) {
            case *utls.ALPNExtension:
                value.AlpnProtocols = []string{"http/1.1"}
            case *utls.ApplicationSettingsExtension:
                // ALPS settings for h2 do not apply to an HTTP/1.1 handshake.
                continue
            }
            extensions = append(extensions, extension)
        }
        spec.Extensions = extensions
        connection := utls.UClient(plain, config, utls.HelloCustom)
        if err := connection.ApplyPreset(&spec); err != nil { return nil, nil, err }
        if err := connection.HandshakeContext(ctx); err != nil { return nil, nil, err }
        state := connection.ConnectionState()
        return connection, &tls.ConnectionState{
            Version: state.Version, HandshakeComplete: state.HandshakeComplete, DidResume: state.DidResume,
            CipherSuite: state.CipherSuite, NegotiatedProtocol: state.NegotiatedProtocol,
            NegotiatedProtocolIsMutual: state.NegotiatedProtocolIsMutual, ServerName: state.ServerName,
            PeerCertificates: state.PeerCertificates, VerifiedChains: state.VerifiedChains,
            SignedCertificateTimestamps: state.SignedCertificateTimestamps, OCSPResponse: state.OCSPResponse,
            TLSUnique: state.TLSUnique,
        }, nil
    })
}
