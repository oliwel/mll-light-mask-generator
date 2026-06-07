IMAGE = mobaprint

.PHONY: build run

build:
	docker build -t $(IMAGE) .

run:
	docker run --rm -p 8080:8080 $(IMAGE)
