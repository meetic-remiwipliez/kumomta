# KumoMTA Migration Documentation

This directory contains the English documentation for the Momentum to KumoMTA migration project.

## Documentation Index

### Configuration

| Document | Description |
|----------|-------------|
| [routing-stirtalk.md](routing-stirtalk.md) | StirTalk routing/policy configuration for assigning messages to the StirTalk pool |
| [lua-modules-config.md](lua-modules-config.md) | Lua modules configuration in KumoMTA (ConfigMap, `dofile` vs `require`) |
| [http-listener-keys.md](http-listener-keys.md) | HTTP Listener Keys secret configuration for API authentication |
| [debug-logging.md](debug-logging.md) | Debug logging configuration for all KumoMTA components |
| [redis-dragonfly-config.md](redis-dragonfly-config.md) | Redis/Dragonfly configuration for shared throttles |
| [sink-mode.md](sink-mode.md) | Sink mode (enabled by default for safe testing) |

### Migration Analysis

| Document | Description |
|----------|-------------|
| [analyse-stirtalk-dallas.md](analyse-stirtalk-dallas.md) | Migration analysis: StirTalk binding group (Dallas) from Momentum to KumoMTA |

### Deployment & Architecture

| Document | Description |
|----------|-------------|
| [kumomta-k8s-demo.md](kumomta-k8s-demo.md) | KumoMTA Kubernetes demo – Many Nodes architecture |
| [helm-chart-readme.md](helm-chart-readme.md) | Helm chart for KumoMTA on Kubernetes (example.com) |
| [architecture.md](architecture.md) | KumoMTA architecture and technical choices |
| [deployment.md](deployment.md) | Deployment guide for KumoMTA on Kubernetes |

### Testing

| Document | Description |
|----------|-------------|
| [tests-readme.md](tests-readme.md) | Test scripts for HTTP and SMTP listeners |
| [testing-guide.md](testing-guide.md) | Testing guide for HTTP and SMTP injection |
