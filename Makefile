.PHONY: init
init:
	./initialiseRepository.sh

.PHONY: db
db:
	./scrapers/databases.sh

