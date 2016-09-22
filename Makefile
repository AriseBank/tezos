
all:
	${MAKE} -C src all

clean:
	${MAKE} -C src clean

.PHONY:test
test:
	${MAKE} -C test

build-deps:
	@./scripts/install_build_deps.sh all
