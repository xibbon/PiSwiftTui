# PiSwiftTui

`PiSwiftTui` is the macOS terminal companion package for `PiSwift`. It contains
the `PiSwiftCodingAgentTui` library and the `pi-coding-agent` executable, while
the mobile-safe agent libraries remain in the sibling `../PiSwift` package.

It depends on the sibling `../PiSwift` and `../MiniTui` packages.

For `pi durable`, see the [PiSwiftCodingAgentDurable README](../PiSwift/Sources/PiSwiftCodingAgentDurable/README.md).

Run the moved test suites with:

```sh
swift test
```

Build or install the executable and extension SDK with:

```sh
make build
make install
```
