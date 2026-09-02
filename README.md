# HoKoPi Platform

This is a **generated, read-only public mirror** of HoKoPi's Platform Engineering work.
The private Webapp monorepo is the source of truth; each publication rebuilds this
repository from filtered Git history and allowlisted Platform paths only.

| Area                                   | Public contents                                                                               |
| -------------------------------------- | --------------------------------------------------------------------------------------------- |
| Containerization and local development | [Dockerfiles and Compose](./docker), [Makefile](./Makefile), [.dockerignore](./.dockerignore) |
| CI/CD definitions                      | [GitHub Actions workflows](./.github/workflows)                                               |
| Operational tooling                    | [Operations scripts and configuration](./ops)                                                 |

Changes must originate from the private source repository. Direct changes or pull
requests to this mirror will be overwritten by a subsequent publication.

## Architecture

HoKoPi currently runs on a **Hetzner Cloud + Docker Compose** architecture, with separate **pre-production** and **production** environments.

```mermaid
flowchart TB

    USER["Users / Internet"]

    subgraph GITHUB["GitHub"]
        WEBAPP["🔒 hokopi-webapp<br/>Private source repository"]
        ACTIONS["GitHub Actions<br/>CI/CD"]
        SECRETS["GitHub Environments<br/>Secrets & Variables"]

        WEBAPP --> ACTIONS
        SECRETS --> ACTIONS
    end

    subgraph HETZNER["Hetzner Cloud"]
        direction TB

        subgraph VM["Linux VM<br/>Preprod / Production"]
            CADDY["Caddy<br/>TLS + Reverse Proxy<br/>:80 / :443"]

            WEBSITE["Website<br/>Static files"]
            FRONTEND["React Webapp<br/>Static files"]
            BACKEND["NestJS API<br/>:3000"]
            OCR["OCR Service<br/>DocTR / Python<br/>:8000"]
            POSTGRES[("PostgreSQL 15<br/>Docker Volume")]

            CADDY --> WEBSITE
            CADDY --> FRONTEND
            CADDY -->|"/api"| BACKEND

            BACKEND --> POSTGRES
            BACKEND --> OCR
        end
    end

    subgraph BACKUP["Remote Backup Infrastructure"]
        RESTIC["Restic Repository<br/>Encrypted backups"]
    end

    subgraph EXTERNAL["External Services"]
        STRIPE["Stripe"]
        MAIL["Resend"]
        AI["AI Providers<br/>Groq / OpenRouter"]
    end

    USER -->|"HTTPS"| CADDY

    ACTIONS -->|"Deployment"| VM

    BACKEND --> STRIPE
    BACKEND --> MAIL
    BACKEND --> AI

    POSTGRES -->|"pg_dump"| RESTIC
```

### Runtime

The application is deployed using **Docker Compose** on Linux VMs hosted at Hetzner.

| Component         | Role                                                                                 |
| ----------------- | ------------------------------------------------------------------------------------ |
| **Caddy**         | HTTPS termination, automatic TLS certificates, static file serving and reverse proxy |
| **Frontend**      | React/Vite HoKoPi web application                                                    |
| **Website**       | Public HoKoPi marketing website                                                      |
| **Backend**       | NestJS REST API                                                                      |
| **OCR**           | Python/DocTR OCR microservice                                                        |
| **PostgreSQL 15** | Primary relational database                                                          |

## About this repository

### Platform mirror workflow and security controls

```mermaid
flowchart TD
    A["🔒 hokopi-webapp<br/>Private source of truth"]

    A --> B{"Publication trigger"}
    B -->|"Manual"| C["main / develop"]
    B -->|"Automatic"| D["Every push to main"]

    C --> E
    D --> E

    subgraph PREP["Preparation"]
        E["🔒 Authorize source"]
        E --> F["Checkout full history<br/>🔒 No persisted credentials"]
        F --> G["Filter history<br/>Allowlisted paths only"]
        G --> H["🔒 Gitleaks<br/>Secret scan"]
    end

    H --> I

    subgraph PUB["Publish"]
        I["Verify destination"]
        I --> J["🔒 Scoped GitHub App"]
        J --> K["Force push"]
    end

    K --> L["🌍 hokopi-platform / main<br/>Public read-only mirror"]

    L --> M["🔒 Actions disabled"]
    L --> N["🔒 Protected by ruleset"]
```

### Security boundary

| Control                         | Protection                                                                                                                                      |
| ------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| 🔒 **Checkout credentials**     | The private Webapp checkout credential is never persisted or reused for publication.                                                            |
| **History filtering**           | `git-filter-repo` rebuilds the repository using only approved Platform paths.                                                                   |
| 🔒 **Secret scanning**          | `Gitleaks` scans the complete filtered Git history before the publication destination is authenticated.                                         |
| 🔒 **Dedicated GitHub App**     | Publications use a credential scoped specifically to `hokopi-platform`.                                                                         |
| 🔒 **Repository ruleset**       | Direct human updates, deletions, and force-pushes to `main` are blocked. The HoKoPi Platform Publisher App is the authorized publication actor. |
| 🔒 **GitHub Actions disabled**  | Mirrored workflow definitions are visible, but cannot execute in the public repository.                                                         |
| 🔒 **Private product boundary** | Application source code, runtime secrets, deployment credentials, private packages, releases, and container images remain private.              |

The public mirror is a **generated, read-only representation of Platform Engineering work**, not an independent deployment repository.
