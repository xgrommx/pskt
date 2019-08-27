
.PHONY: all
all:  build test-codegen test-generatekt test run

.PHONY: run
run: test
	java -jar kotlin/bin.jar

.PHONY: test
test:
	kotlinc kotlin/*.kt kotlin/Foreign/*.kt -include-runtime -d kotlin/bin.jar
	
		# -i "test/output/Data.Unit/corefn.json"\
		# -i "test/output/Data.Show/corefn.json"\
		# -i "test/output/Data.Symbol/corefn.json"\
		# -i "test/output/Type.Data.RowList/corefn.json"\
		# -i "test/output/Type.Data.Row/corefn.json"\
		# -i "test/output/Record.Unsafe/corefn.json"\
		# -i "test/output/Data.Semigroup/corefn.json"\
		# -i "test/output/Data.Semiring/corefn.json"\
		# -i "test/output/Control.Semigroupoid/corefn.json"\
		# -i "test/output/Data.Void/corefn.json"\

test-generatekt: build
	stack exec -- pskt --print-corefn \
		-i "test/output/Main/corefn.json"\
		-o ./kotlin/

.PHONY: test-codegen
test-codegen: build
	cd test && spago build -- -g corefn && cd ..
	# purs compile --codegen corefn test/src/Main.purs test/.spago/console/v4.2.0/src/**/*.purs test/.spago/effect/v2.0.1/src/**/*.purs test/.spago/prelude/v4.1.1/src/**/*.purs test/.spago/psci-support/v4.0.0/src/**/*.purs test/src/**/*.purs test/test/**/*.purs


.PHONY: build
build:
	stack build --fast