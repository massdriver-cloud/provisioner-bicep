# Makefile for building Docker image

# Variables
IMAGE_NAME := 005022811284.dkr.ecr.us-west-2.amazonaws.com/massdriver-cloud/prov-bicep
TAG := latest

# Default target
all: build

# Build Docker image
build:
	docker build -t $(IMAGE_NAME):$(TAG) .

# Push Docker image to registry
push:
	docker push $(IMAGE_NAME):$(TAG)

# Clean up Docker images
clean:
	docker rmi $(IMAGE_NAME):$(TAG)

.PHONY: all build push clean