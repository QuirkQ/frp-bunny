# frp-bunny

Hardened [frp](https://github.com/fatedier/frp) server (`frps`) Docker image designed for [Bunny Magic Containers](https://bunny.net/magic-containers/). Secrets are passed via environment variables at runtime — nothing is baked into the image.

## Architecture

```
[Your service] → frpc (client, TLS) → frps on Magic Containers → Public internet
```

## Quick Start

```bash
docker run -d \
  -e FRP_TOKEN=your-secret-token \
  -p 7000:7000 \
  ghcr.io/quirkq/frp-bunny:latest
```

## Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `FRP_TOKEN` | Yes | — | Auth token shared between frps and frpc |
| `PUID` | No | `1000` | UID for the frps process |
| `PGID` | No | `1000` | GID for the frps process |
| `BIND_PORT` | No | `7000` | Port frpc clients connect to |
| `MAX_PORTS_PER_CLIENT` | No | `5` | Max remote ports a single client can claim |
| `MAX_POOL_COUNT` | No | `5` | Max connection pool size per proxy |
| `ALLOW_PORTS` | No | `10000-50000` | Port ranges clients may bind (comma-separated, e.g. `20000-30000,40000-40100`) |
| `DASHBOARD_PASSWORD` | No | *(unset)* | Enables the dashboard when set |
| `DASHBOARD_USER` | No | `admin` | Dashboard login username |
| `DASHBOARD_PORT` | No | `7500` | Dashboard port |
| `DASHBOARD_ADDR` | No | `127.0.0.1` | Dashboard bind address |
| `ENABLE_PROMETHEUS` | No | `false` | Expose Prometheus metrics at `/metrics` (requires dashboard) |
| `VHOST_HTTP_PORT` | No | *(unset)* | Enables HTTP vhost proxying when set |
| `VHOST_HTTPS_PORT` | No | *(unset)* | Enables HTTPS vhost proxying when set |
| `SUBDOMAIN_HOST` | No | *(unset)* | Restrict vhost subdomain claims to this base domain |
| `TLS_CERT_FILE` | No | `/etc/frp/tls/server.crt` | Server TLS certificate path |
| `TLS_KEY_FILE` | No | `/etc/frp/tls/server.key` | Server TLS private key path |
| `TLS_CA_FILE` | No | `/etc/frp/tls/ca.crt` | CA certificate for mTLS client verification |
| `TLS_CERT_B64` | No | *(unset)* | Base64-encoded server certificate (alternative to mounting files) |
| `TLS_KEY_B64` | No | *(unset)* | Base64-encoded server private key |
| `TLS_CA_B64` | No | *(unset)* | Base64-encoded CA certificate |

## TLS and mTLS

By default, TLS is required between frpc and frps (`transport.tls.force = true`), but uses frp's built-in auto-generated certificates. This encrypts traffic but doesn't verify identity — an attacker could MITM the connection and brute-force the token.

For production, mount proper certificates to enable server identity verification and optionally mTLS (mutual TLS) for client certificate authentication. frp uses its own TLS transport, so certificates are **not domain-bound** — self-signed certs work fine.

### Generating certificates

A helper script is included to generate all certificates at once:

```bash
# Default: 1 server cert, 1 client cert, new CA
./generate-certs.sh

# 2 servers, 5 clients
./generate-certs.sh -s 2 -c 5

# Use an existing CA
./generate-certs.sh -c 3 --ca-cert ./ca.crt --ca-key ./ca.key

# Custom output dir, key size, and validity
./generate-certs.sh -d ./my-certs -b 2048 -y 5
```

Run `./generate-certs.sh --help` for all options. The script automatically sets restrictive file permissions (`700` on the directory, `600` on private keys).

This gives you:

| File | Goes on | Purpose |
|---|---|---|
| `ca.crt` | Server + all clients | CA certificate — both sides verify certs against this |
| `ca.key` | **Keep offline/safe** | Only needed to sign new certs |
| `server.crt` + `server.key` | Server (frps) | Server identity |
| `client.crt` + `client.key` | Client (frpc) | Client identity |

### Server setup (frps)

Mount the three server files into the container:

```bash
docker run -d \
  -e FRP_TOKEN=your-secret-token \
  -v ./certs/ca.crt:/etc/frp/tls/ca.crt:ro \
  -v ./certs/server.crt:/etc/frp/tls/server.crt:ro \
  -v ./certs/server.key:/etc/frp/tls/server.key:ro \
  -p 7000:7000 \
  ghcr.io/quirkq/frp-bunny:latest
```

The entrypoint auto-detects the mounted certs:
- `server.crt` + `server.key` present → enables server TLS identity
- `ca.crt` also present → enables **mTLS** (clients must present a valid certificate)

Alternatively, pass certificates as base64-encoded environment variables (useful for platforms that don't support volume mounts, like Bunny Magic Containers):

```bash
docker run -d \
  -e FRP_TOKEN=your-secret-token \
  -e TLS_CERT_B64=$(base64 < certs/server.crt) \
  -e TLS_KEY_B64=$(base64 < certs/server.key) \
  -e TLS_CA_B64=$(base64 < certs/ca.crt) \
  -p 7000:7000 \
  ghcr.io/quirkq/frp-bunny:latest
```

The `_B64` env vars are decoded to files at startup. If both a mounted file and a `_B64` var exist, the decoded env var takes precedence.

### Client setup (frpc)

Update your `frpc.toml` to use the client certificate and verify the server:

```toml
serverAddr = "your-magic-endpoint.b-cdn.net"
serverPort = 7000

auth.token = "your-secret-token"

transport.tls.enable = true
transport.tls.certFile = "/path/to/client.crt"
transport.tls.keyFile = "/path/to/client.key"
transport.tls.trustedCaFile = "/path/to/ca.crt"

[[proxies]]
name = "my-service"
type = "tcp"
localIP = "127.0.0.1"
localPort = 3000
remotePort = 20000
```

With mTLS enabled, even if an attacker obtains the token, they cannot connect without a valid client certificate signed by your CA.

## Deploy on Bunny Magic Containers

1. Push the image to GHCR (the GitHub Actions workflow does this automatically on every push to `main`).
2. In the [bunny.net dashboard](https://dash.bunny.net), go to **Magic Containers** and create a new app.
3. Set the container image to `ghcr.io/quirkq/frp-bunny:latest`.
4. Add `FRP_TOKEN` as an environment variable in the container config.
5. Add an endpoint for port **7000** (Anycast) — this is the frpc connection port.
6. Use **Single Region** deployment — multiple frps instances can't share the same ports, and anycast routing would scatter frpc connections.

Note the public hostname assigned to your endpoint — this is your `serverAddr` for frpc.

## Client Config (frpc)

The frpc client must also enable TLS to match the server. Minimal `frpc.toml`:

```toml
serverAddr = "your-magic-endpoint.b-cdn.net"
serverPort = 7000

auth.token = "your-secret-token"
transport.tls.enable = true
loginFailExit = false

[[proxies]]
name = "my-service"
type = "tcp"
localIP = "127.0.0.1"
localPort = 3000
remotePort = 20000
```

> `loginFailExit = false` keeps frpc retrying on connection failure instead of exiting.
>
> `remotePort` must fall within the server's allowed range (default `10000-50000`).

See the [mTLS section](#client-setup-frpc) for adding client certificate authentication.

## Image Tags

| Tag | Description |
|---|---|
| `latest` | Latest stable frp release |
| `0` | Latest 0.x |
| `0.61` | Latest 0.61.x |
| `0.61.1` | Specific frp version |

## Hardening

- TLS enforced on the frpc-frps connection
- mTLS support — auto-enabled when certs are mounted
- Token re-validated on every heartbeat and new connection (`auth.additionalScopes`)
- Allowed port ranges restricted (`allowPorts`, default `10000-50000`)
- Port claims capped per client (`maxPortsPerClient`)
- Connection pool capped per proxy (`transport.maxPoolCount`)
- Runs as non-root user (`frps`) with configurable UID/GID via `PUID`/`PGID`
- Compatible with `--user` / Kubernetes `securityContext` for rootless operation
- Dashboard disabled by default, bound to `127.0.0.1` when enabled
- Dashboard TLS auto-enabled when server certs are mounted
- Vhost ports disabled by default (opt-in via env vars)
- `detailedErrorsToClient = false` prevents info leakage
- Config file generated at startup with `400` permissions
- Port and env var inputs validated; strings escaped for TOML injection prevention
- Trivy vulnerability scan on every build
- Go version auto-detected at build time for latest security patches
- Scheduled builds pick up new upstream frp releases automatically

## License

[Apache 2.0](LICENSE)
