# HoKoPi Delivery & Operations

This is a **generated, read-only public mirror** of HoKoPi's DevOps, infrastructure and cloud-native delivery work.
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
        WEBAPPREPO["🔒 hokopi-webapp<br/>Private source repository"]
        ACTIONS["GitHub Actions<br/>CI/CD"]
        SECRETS["GitHub Environments<br/>Secrets & Variables"]

        WEBAPPREPO --> ACTIONS
        SECRETS --> ACTIONS
    end

    subgraph HETZNER["Hetzner Cloud"]
        direction TB

        subgraph VM["Linux VM<br/>Preprod / Production"]
            TRAEFIK["Traefik<br/>TLS + Reverse Proxy<br/>:80 / :443"]

            WEBSITE["Website<br/>Nginx (static files)"]
            WEBAPP["React Webapp<br/>Nginx (static files)"]
            BACKEND["NestJS API<br/>:3000"]
            OCR["OCR Service<br/>DocTR / Python<br/>:8000"]
            POSTGRES[("PostgreSQL 15<br/>Docker Volume")]

            TRAEFIK --> WEBSITE
            TRAEFIK --> WEBAPP
            TRAEFIK -->|"/api"| BACKEND

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

    USER -->|"HTTPS"| TRAEFIK

    ACTIONS -->|"Deployment"| VM

    BACKEND --> STRIPE
    BACKEND --> MAIL
    BACKEND --> AI

    POSTGRES -->|"pg_dump"| RESTIC
```

### Runtime

The application is deployed using **Docker Compose** on Linux VMs hosted at Hetzner.

| Component         | Role                                                            |
| ----------------- | --------------------------------------------------------------- |
| **Traefik**       | HTTPS termination, automatic TLS certificates and reverse proxy |
| **Webapp**        | React/Vite HoKoPi application, served internally by Nginx       |
| **Website**       | Public HoKoPi website, served internally by Nginx               |
| **Backend**       | NestJS REST API                                                 |
| **OCR**           | Python/DocTR OCR microservice                                   |
| **PostgreSQL 15** | Primary relational database                                     |

Traefik discovers only explicitly enabled Docker services (`traefik.enable=true`).
Its dashboard is not exposed on a public port. TLS certificates are persisted in
the `letsencrypt` Docker volume.

## CI/CD

CI/CD is orchestrated by GitHub Actions.

```mermaid
flowchart TB
    PR["Pull Request"]

    subgraph CI["CI — Quality & Security"]
        direction TB

        SECRETS["🔐 Secret Scanning<br/>Gitleaks"]

        subgraph QUALITY["Quality Checks"]
            direction LR

            subgraph BACKEND["Backend"]
                direction TB
                B_LINT["Lint"]
                B_TEST["Tests"]
                B_BUILD["Build"]

                B_LINT --> B_TEST --> B_BUILD
            end

            subgraph WEBAPP["Webapp"]
                direction TB
                W_LINT["Lint"]
                W_BUILD["Build"]

                W_LINT --> W_BUILD
            end
        end

        CI_GATE{"CI Passed?"}

        SECRETS --> B_LINT
        SECRETS --> W_LINT

        B_BUILD --> CI_GATE
        W_BUILD --> CI_GATE
    end

    MERGE["PR Approved & Merged"]

    subgraph CD["CD — Deployment"]
        direction TB

        RELEASE_BUILD["Build"]
        DEPLOY["Deploy"]

        RELEASE_BUILD --> DEPLOY
    end

    PR --> SECRETS
    CI_GATE -->|Yes| MERGE
    MERGE --> RELEASE_BUILD
```

## About this repository

### Mirror workflow and security controls

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

The public mirror is a **generated, read-only representation of HoKoPi's current
delivery and operations stack**, not an independent deployment repository.
