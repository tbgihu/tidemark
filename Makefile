.PHONY: install update build test identity uninstall clean

## make install    create the signing identity, build, and install to ~/Applications/Tidemark.app
install:
	@scripts/identity.sh
	@scripts/build.sh
	@scripts/install.sh

## make update     build the newest commit of the upstream (fast-forward only) and install it now
update:
	@scripts/update.sh

## make build      build build/Tidemark.app only (DEBUG=1 for a debug build with --sample data)
build:
	@scripts/build.sh

## make test       run the unit tests
test:
	@scripts/test.sh

## make identity   create the local signing certificate
identity:
	@scripts/identity.sh

## make uninstall  remove Tidemark, everything it stored and then this clone, after asking
uninstall:
	@scripts/uninstall.sh

## make clean      remove build products
clean:
	@rm -rf build .build
