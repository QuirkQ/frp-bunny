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
| `BIND_PORT` | No | `7000` | Port frpc clients connect to |
| `MAX_PORTS_PER_CLIENT` | No | `5` | Max remote ports a single client can claim |
| `DASHBOARD_PASSWORD` | No | *(unset)* | Enables the dashboard when set |
| `DASHBOARD_USER` | No | `admin` | Dashboard login username |
| `DASHBOARD_PORT` | No | `7500` | Dashboard port |
| `VHOST_HTTP_PORT` | No | *(unset)* | Enables HTTP vhost proxying when set |
| `VHOST_HTTPS_PORT` | No | *(unset)* | Enables HTTPS vhost proxying when set |

## Defaults

The image ships with a secure-by-default config:

- **TLS required** between frpc and frps (`transport.tls.force = true`)
- **Dashboard disabled** unless `DASHBOARD_PASSWORD` is explicitly set
- **Vhost ports disabled** unless `VHOST_HTTP_PORT` / `VHOST_HTTPS_PORT` are set
- **Port claims capped** at 5 per client (`maxPortsPerClient`)
- **Error details hidden** from clients (`detailedErrorsToClient = false`)

## Deploy on Bunny Magic Containers

1. Push the image to GHCR (the GitHub Actions workflow does this automatically on every push to `main`).
2. In the [bunny.net dashboard](https://dash.bunny.net), go to **Magic Containers** and create a new app.
3. Set the container image to `ghcr.io/quirkq/frp-bunny:latest`.
4. Add `FRP_TOKEN` as an environment variable in the container config.
5. Add an endpoint for port **7000** (Anycast) — this is the frpc connection port.
6. Use **Single Region** deployment — multiple frps instances can't share the same ports, and anycast routing would scatter frpc connections.

Note the public hostname assigned to your endpoint — this is your `serverAddr` for frpc.

## Client Config (frpc)

The frpc client must also enable TLS to match the server. Example `frpc.toml`:

```toml
serverAddr = "your-magic-endpoint.b-cdn.net"
serverPort = 7000

auth.token = "your-secret-token"
transport.tls.enable = true

[[proxies]]
name = "my-service"
type = "tcp"
localIP = "127.0.0.1"
localPort = 3000
remotePort = 8080
```

## Image Tags

| Tag | Description |
|---|---|
| `latest` | Latest stable frp release |
| `0` | Latest 0.x |
| `0.61` | Latest 0.61.x |
| `0.61.1` | Specific frp version |

## Hardening

- TLS enforced on the frpc-frps connection
- Runs as non-root user (`frps`)
- Dashboard disabled by default (opt-in via `DASHBOARD_PASSWORD`)
- Vhost ports disabled by default (opt-in via env vars)
- `maxPortsPerClient` caps port claims per client
- `detailedErrorsToClient = false` prevents info leakage
- Config file generated at startup with `400` permissions
- Port and env var inputs validated; strings escaped for TOML injection prevention
- Trivy vulnerability scan on every build
- Scheduled builds pick up new upstream frp releases automatically

## License

[Apache 2.0](LICENSE)
