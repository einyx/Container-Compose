# Container-Compose

Container-Compose brings (limited) Docker Compose support to [Apple Container](https://github.com/apple/container), allowing you to define and orchestrate multi-container applications on Apple platforms using familiar Compose files. This project is not a Docker or Docker Compose wrapper but a tool to bridge Compose workflows with Apple's container management ecosystem.

> **Note:** Container-Compose does not automatically configure DNS for macOS 15 (Sequoia). Use macOS 26 (Tahoe) for an optimal experience.

## Features

- **Compose file support:** Parse and interpret `docker-compose.yml` files to configure Apple Containers.
- **Apple Container orchestration:** Launch and manage multiple containerized services using Apple’s native container runtime.
- **Environment configuration:** Support for environment variable files (`.env`) to customize deployments.
- **Service dependencies:** Specify service dependencies and startup order.
- **Volume and network mapping:** Map data and networking as specified in Compose files to Apple Container equivalents.
- **Extensible:** Designed for future extension and customization.

## Getting Started

### Prerequisites

- A Mac running macOS with Apple Container support (macOS Sonoma or later recommended)
- Git
- [Xcode command line tools](https://developer.apple.com/xcode/resources/) (for building, if building from source)

### Installation

You can install Container-Compose via **Homebrew** (recommended):

```sh
brew update
brew install container-compose
````

Or, build it from source:

1. **Clone the repository:**

   ```sh
   git clone https://github.com/Mcrich23/Container-Compose.git
   cd Container-Compose
   ```

2. **Build the executable:**

   > *Note: Ensure you have Swift installed (or the required toolchain).*

   ```sh
   make build
   ```

3. **(Optional)**: Install globally

   ```sh
   make install
   ```

### Usage

After installation, simply run:

```sh
container-compose up
```

You may need to provide a path to your `docker-compose.yml` and `.env` file as arguments.

## Contributing

Contributions are welcome! Please open issues or submit pull requests to help improve this project.

1. Fork the repository.
2. Create your feature branch (`git checkout -b feat/YourFeature`).
3. Commit your changes (`git commit -am 'Add new feature'`).
4. Add tests to you changes.
5. Push to the branch (`git push origin feature/YourFeature`).
6. Open a pull request.

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

## Support

If you encounter issues or have questions, please open an [Issue](https://github.com/Mcrich23/Container-Compose/issues).

---

Happy Coding! 🚀

## Shared (host-backed) named volumes

apple/container attaches a named volume (a sparse disk image) to a single VM at
a time, so two containers cannot mount the same block volume concurrently —
init/sidecar patterns fail with `The storage device attachment is invalid`.

`container-compose` works around this by backing volumes referenced by **two or
more services** with a host directory (virtiofs bind mount) instead of a block
volume. Data lives under
`~/Library/Application Support/com.apple.container/shared-volumes/<project>_<name>/`.

Control the behavior with `CONTAINER_COMPOSE_SHARED_VOLUMES`:

| Value    | Behavior                                              |
|----------|-------------------------------------------------------|
| `auto`   | (default) share volumes referenced by 2+ services      |
| `always` | host-back every named volume                           |
| `never`  | classic block volumes (single-VM attachment applies)   |

### Limitations

- **Unix domain sockets do not cross virtiofs** (`connect()` fails with
  `Errno 95`). Volumes used to share sockets between containers (e.g. a
  `/var/run/postgresql` socket sidecar) cannot work on apple/container in any
  mode — use TCP instead.
- The guest cannot `chown`/`chmod` files on shared volumes (ownership is
  mapped from the host user). Images whose entrypoints insist on changing
  permissions inside such a mount will fail; keep shared volumes pointed at
  paths the image does not mutate permissions on.
- I/O performance matches virtiofs, not a native block device — avoid for
  write-heavy data directories.
