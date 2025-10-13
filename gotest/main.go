// main.go
package main

import (
    "fmt"
    "os"
    "os/signal"
    "syscall"
)

// Large static array to pad binary size (~100MB)
var padding [100 * 1024 * 1024]byte

func main() {
    // Initialize padding to prevent compiler optimization
    for i := range padding {
        padding[i] = byte(i % 256)
    }

    fmt.Println("ready")

    // Setup signal handling
    sigChan := make(chan os.Signal, 1)
    signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

    // Wait for signal
    <-sigChan
    fmt.Println("shutting down")
}
