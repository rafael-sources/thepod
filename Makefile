# Pruebas de todas las apps web (cada una con su propio intérprete si lo tiene)
test:
	@for a in pre prod ama post; do echo "== $$a"; (cd apps/$$a && python3 -m pytest -q tests 2>&1 | tail -2); done
	@echo "== thepod"; (cd apps/thepod && python3 tests/i18n_escenarios.py | tail -1 && python3 tests/billing_escenarios.py | grep -c '^OK')
