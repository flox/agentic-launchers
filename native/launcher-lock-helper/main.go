package main

import (
	"errors"
	"fmt"
	"os"
	"strconv"
	"syscall"
	"time"
)

const (
	exitUsage   = 64
	exitData    = 65
	exitTimeout = 75
	exitParent  = 76
)

func usage() {
	fmt.Fprintln(os.Stderr, "usage:")
	fmt.Fprintln(os.Stderr, "  launcher-lock-helper acquire-fd <fd> <path> <timeout-seconds>")
	fmt.Fprintln(os.Stderr, "  launcher-lock-helper replace-file <source> <target>")
}

func isRegular(mode uint32) bool {
	return mode&syscall.S_IFMT == syscall.S_IFREG
}

func sameIdentity(left, right *syscall.Stat_t) bool {
	return left.Dev == right.Dev && left.Ino == right.Ino
}

func sameOpenFile(fd int, path string) error {
	var fdStat syscall.Stat_t
	var pathStat syscall.Stat_t
	if err := syscall.Fstat(fd, &fdStat); err != nil {
		return fmt.Errorf("fstat descriptor %d: %w", fd, err)
	}
	if !isRegular(uint32(fdStat.Mode)) {
		return fmt.Errorf("lock descriptor %d is not a regular file", fd)
	}
	if err := syscall.Lstat(path, &pathStat); err != nil {
		return fmt.Errorf("lstat lock path: %w", err)
	}
	if !isRegular(uint32(pathStat.Mode)) {
		return fmt.Errorf("lock path is not a regular non-symlink file")
	}
	if !sameIdentity(&fdStat, &pathStat) {
		return fmt.Errorf("lock path changed while opening")
	}
	return nil
}

func parentAlive(parentPID int) bool {
	return parentPID > 1 && os.Getppid() == parentPID
}

func acquireFD(fd int, path string, timeout time.Duration) int {
	parentPID := os.Getppid()
	if parentPID <= 1 {
		fmt.Fprintln(os.Stderr, "lock owner is already absent")
		return exitParent
	}
	if err := sameOpenFile(fd, path); err != nil {
		fmt.Fprintf(os.Stderr, "invalid lock object %s: %v\n", path, err)
		return exitData
	}
	if err := syscall.Fchmod(fd, 0o600); err != nil {
		fmt.Fprintf(os.Stderr, "cannot set private lock mode on %s: %v\n", path, err)
		return exitData
	}

	deadline := time.Now().Add(timeout)
	for {
		if !parentAlive(parentPID) {
			return exitParent
		}
		err := syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			break
		}
		if !errors.Is(err, syscall.EWOULDBLOCK) && !errors.Is(err, syscall.EAGAIN) {
			fmt.Fprintf(os.Stderr, "kernel lock failed for %s: %v\n", path, err)
			return exitData
		}
		if timeout <= 0 || !time.Now().Before(deadline) {
			fmt.Fprintf(os.Stderr, "timed out waiting for kernel lock: %s\n", path)
			return exitTimeout
		}
		time.Sleep(20 * time.Millisecond)
	}

	// Bind success to the same persistent pathname after acquisition. No code in
	// the launcher ever unlinks this file; subsequent owners lock this inode.
	if err := sameOpenFile(fd, path); err != nil {
		_ = syscall.Flock(fd, syscall.LOCK_UN)
		fmt.Fprintf(os.Stderr, "lock path changed during acquisition %s: %v\n", path, err)
		return exitData
	}
	if !parentAlive(parentPID) {
		_ = syscall.Flock(fd, syscall.LOCK_UN)
		return exitParent
	}

	// Do not unlock. flock ownership is attached to the inherited open-file
	// description. The Bash owner retains that description after this helper
	// exits, and close/process death releases it in the kernel.
	return 0
}

func openRegularNoFollow(path string) (int, syscall.Stat_t, error) {
	var before syscall.Stat_t
	var opened syscall.Stat_t

	if err := syscall.Lstat(path, &before); err != nil {
		return -1, opened, fmt.Errorf("lstat source: %w", err)
	}
	if !isRegular(uint32(before.Mode)) {
		return -1, opened, fmt.Errorf("source is not a regular non-symlink file")
	}

	fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_CLOEXEC|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return -1, opened, fmt.Errorf("open source without following symlinks: %w", err)
	}
	if err := syscall.Fstat(fd, &opened); err != nil {
		_ = syscall.Close(fd)
		return -1, opened, fmt.Errorf("fstat source: %w", err)
	}
	if !isRegular(uint32(opened.Mode)) || !sameIdentity(&before, &opened) {
		_ = syscall.Close(fd)
		return -1, opened, fmt.Errorf("source changed while opening")
	}
	return fd, opened, nil
}

func validateReplaceTarget(path string) error {
	var target syscall.Stat_t
	err := syscall.Lstat(path, &target)
	if errors.Is(err, syscall.ENOENT) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("lstat target: %w", err)
	}
	if !isRegular(uint32(target.Mode)) {
		return fmt.Errorf("target is not a regular non-symlink file")
	}
	return nil
}

// replaceFile performs one pathname-to-pathname rename, not command-line mv
// directory semantics. The source remains open throughout so success can be
// bound to the exact inode now published at target. The source and target are
// created in the same directory by the caller, so cross-device rename is not an
// expected or supported case.
func replaceFile(source, target string) int {
	fd, sourceStat, err := openRegularNoFollow(source)
	if err != nil {
		fmt.Fprintf(os.Stderr, "invalid publication source %s: %v\n", source, err)
		return exitData
	}
	defer func() { _ = syscall.Close(fd) }()

	if err := validateReplaceTarget(target); err != nil {
		fmt.Fprintf(os.Stderr, "invalid publication target %s: %v\n", target, err)
		return exitData
	}
	if err := syscall.Rename(source, target); err != nil {
		fmt.Fprintf(os.Stderr, "cannot atomically replace %s: %v\n", target, err)
		return exitData
	}

	var published syscall.Stat_t
	if err := syscall.Lstat(target, &published); err != nil {
		fmt.Fprintf(os.Stderr, "cannot verify published target %s: %v\n", target, err)
		return exitData
	}
	if !isRegular(uint32(published.Mode)) || !sameIdentity(&sourceStat, &published) {
		fmt.Fprintf(os.Stderr, "publication postcondition failed for %s\n", target)
		return exitData
	}
	return 0
}

func main() {
	if len(os.Args) == 5 && os.Args[1] == "acquire-fd" {
		fd, err := strconv.Atoi(os.Args[2])
		if err != nil || fd < 3 {
			fmt.Fprintln(os.Stderr, "invalid lock descriptor")
			os.Exit(exitUsage)
		}
		seconds, err := strconv.Atoi(os.Args[4])
		if err != nil || seconds < 0 {
			fmt.Fprintln(os.Stderr, "invalid lock timeout")
			os.Exit(exitUsage)
		}
		os.Exit(acquireFD(fd, os.Args[3], time.Duration(seconds)*time.Second))
	}

	if len(os.Args) == 4 && os.Args[1] == "replace-file" {
		os.Exit(replaceFile(os.Args[2], os.Args[3]))
	}

	usage()
	os.Exit(exitUsage)
}
