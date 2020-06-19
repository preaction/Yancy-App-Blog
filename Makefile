
build:
	docker-compose build

up:
	docker-compose up

test:
	docker-compose run web prove -v

deploy:
	@echo "❌ No deploy written yet"

sql:
	docker-compose start db
	docker-compose exec db psql -U postgres
