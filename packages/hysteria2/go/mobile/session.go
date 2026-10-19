package hybridge

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"net"
	"strings"
	"sync"
	"time"

	"github.com/apernet/hysteria/core/v2/client"
	coreerrors "github.com/apernet/hysteria/core/v2/errors"
	"github.com/apernet/hysteria/extras/v2/obfs"
	"github.com/apernet/quic-go"
)

const handshakeTimeout = 12 * time.Second

type endpoint struct {
	Host     string `json:"host"`
	Port     int    `json:"port"`
	Username string `json:"username"`
	Password string `json:"password"`
}

type tcpCore interface {
	TCP(string) (net.Conn, error)
	Close() error
}

type session struct {
	mu      sync.Mutex
	cfg     config
	roots   *x509.CertPool // Test injection only. Public config cannot override trust.
	timeout time.Duration
	ctx     context.Context
	cancel  context.CancelFunc
	started bool
	closed  bool
	done    chan struct{}
	ep      endpoint
	err     error
	core    tcpCore
	proxy   *proxy
}

func newSession(cfg config, roots *x509.CertPool, timeout time.Duration) *session {
	ctx, cancel := context.WithCancel(context.Background())
	return &session{cfg: cfg, roots: roots, timeout: timeout, ctx: ctx, cancel: cancel, done: make(chan struct{})}
}

func (s *session) connect() (endpoint, error) {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return endpoint{}, errors.New("HYSTERIA_CANCELLED")
	}
	start := !s.started
	s.started = true
	s.mu.Unlock()
	if start {
		s.open()
	}
	select {
	case <-s.done:
		s.mu.Lock()
		defer s.mu.Unlock()
		if s.closed {
			return endpoint{}, errors.New("HYSTERIA_CANCELLED")
		}
		return s.ep, s.err
	case <-s.ctx.Done():
		return endpoint{}, errors.New("HYSTERIA_CANCELLED")
	}
}

func (s *session) open() {
	core, err := dialCore(s.ctx, s.cfg, s.roots, s.timeout)
	var p *proxy
	if err == nil {
		p, err = newProxy(core)
		if err != nil {
			_ = core.Close()
			err = errors.New("HYSTERIA_LISTENER")
		}
	}
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		if p != nil {
			p.close()
			_ = core.Close()
		}
		close(s.done)
		return
	}
	s.core, s.proxy, s.err = core, p, err
	if p != nil {
		s.ep = p.ep
	}
	s.mu.Unlock()
	close(s.done)
}

func (s *session) close() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	s.cancel()
	p, core := s.proxy, s.core
	s.proxy, s.core = nil, nil
	s.mu.Unlock()
	if p != nil {
		p.close()
	}
	if core != nil {
		_ = core.Close()
	}
}

// Upstream NewClient has no context parameter. Closing its owned packet socket
// makes cancellation interrupt both QUIC establishment and the auth response.
func dialCore(parent context.Context, cfg config, roots *x509.CertPool, timeout time.Duration) (tcpCore, error) {
	ctx, cancel := context.WithTimeout(parent, timeout)
	defer cancel()
	ips, err := net.DefaultResolver.LookupIPAddr(ctx, cfg.Host)
	if err != nil || len(ips) == 0 {
		return nil, safeConnectError(ctx, err)
	}
	addr := &net.UDPAddr{IP: ips[0].IP, Port: cfg.Port}
	udp, err := net.ListenUDP("udp", nil)
	if err != nil {
		return nil, errors.New("HYSTERIA_CONNECT")
	}
	var packet net.PacketConn = udp
	if cfg.ObfsPassword != "" {
		packet, err = obfs.WrapPacketConnSalamander(udp, []byte(cfg.ObfsPassword))
		if err != nil {
			_ = udp.Close()
			return nil, errors.New("HYSTERIA_CONFIG")
		}
	}
	stop := context.AfterFunc(ctx, func() { _ = packet.Close() })
	c, _, err := client.NewClient(&client.Config{
		ServerAddr: addr, Auth: cfg.Auth, ConnFactory: &packetFactory{packet},
		TLSConfig:  client.TLSConfig{ServerName: cfg.SNI, RootCAs: roots},
		QUICConfig: client.QUICConfig{DisableGSO: true},
		// FastOpen permits a per-stream deadline before waiting for server dialing.
		FastOpen: true,
	})
	stopped := stop()
	if err != nil || !stopped || ctx.Err() != nil {
		if c != nil {
			_ = c.Close()
		}
		_ = packet.Close()
		return nil, safeConnectError(ctx, err)
	}
	return c, nil
}

type packetFactory struct{ conn net.PacketConn }

func (f *packetFactory) New(net.Addr) (net.PacketConn, error) { return f.conn, nil }

func safeConnectError(ctx context.Context, err error) error {
	if errors.Is(ctx.Err(), context.Canceled) {
		return errors.New("HYSTERIA_CANCELLED")
	}
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return errors.New("HYSTERIA_TIMEOUT")
	}
	var certErr *tls.CertificateVerificationError
	var unknownCA x509.UnknownAuthorityError
	var hostname x509.HostnameError
	if errors.As(err, &certErr) || errors.As(err, &unknownCA) || errors.As(err, &hostname) {
		return errors.New("HYSTERIA_TLS")
	}
	// Upstream uTLS may discard the x509 error and report a local INTERNAL_ERROR.
	// Recognize only its constant prefix; never expose the diagnostic itself.
	var transport *quic.TransportError
	if errors.As(err, &transport) {
		if (transport.ErrorCode >= 0x100 && transport.ErrorCode <= 0x1ff) ||
			(!transport.Remote && strings.HasPrefix(transport.ErrorMessage, "tls: failed to verify certificate:")) {
			return errors.New("HYSTERIA_TLS")
		}
	}
	var timeoutError net.Error
	if errors.As(err, &timeoutError) && timeoutError.Timeout() {
		return errors.New("HYSTERIA_TIMEOUT")
	}
	var auth coreerrors.AuthError
	if errors.As(err, &auth) {
		return errors.New("HYSTERIA_AUTH")
	}
	return errors.New("HYSTERIA_CONNECT")
}
