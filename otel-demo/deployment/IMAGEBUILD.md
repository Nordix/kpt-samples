# Building the branded images

The `otel-demo` app package references the branded store images by their
**registry-qualified** names, pre-published under:

```
ghcr.io/kptdev/kpt-samples/otel-demo/<name>:<tag>
```

In the normal flow you do **not** build anything — region clusters pull these
images from the registry over the network. This document is only for:

- **Publishing** the images to the registry (maintainers), or
- **Building locally** for offline/air-gapped clusters or when iterating on the
  image sources, and side-loading them into a kind cluster.

> The deploy script (`deploy.sh`) also automates local builds — see
> [`deploy.sh build`](#via-deploysh) below. This doc covers the manual `docker`
> steps. For the full deployment runbook, see [MANUAL.md](./MANUAL.md).

## Images

Per store, built from `./<store>/<dir>`:

| Image name                | Source dir (`<store>/…`) | astronomy | florist |
|---------------------------|--------------------------|:---------:|:-------:|
| `<store>-frontend`        | `frontend`               | ✅ | ✅ |
| `<store>-ad`              | `ad`                     | ✅ | ✅ |
| `<store>-llm`             | `llm`                    | ✅ | ✅ |
| `<store>-email` / `email` | `email`                  | ✅ (`astronomy-email`) | ✅ (`email`) |
| `florist-image-provider`  | `image-provider`         | — (uses upstream) | ✅ |
| `florist-load-generator`  | `load-generator`         | — (uses upstream) | ✅ |

Notes:
- Astronomy's **image-provider** and **load-generator** are **not** branded — the
  package uses the upstream `ghcr.io/open-telemetry/demo:2.2.0-{image-provider,load-generator}`
  images for astronomy. Only florist ships branded variants of those two.
- Florist's email image is published as the shared `email` (no `florist-` prefix),
  matching the branding config.
- The `ad` image is a Java service and takes an OpenTelemetry Java agent version
  as a build arg.

## Environment

```bash
export REPO=$(pwd)                                        # repo root (contains astronomy/ and florist/)
export IMAGE_REGISTRY=ghcr.io/kptdev/kpt-samples/otel-demo
export IMAGE_TAG=v1
export OTEL_JAVA_AGENT_VERSION=2.11.0                     # for the 'ad' (Java) image
```

## Build

### Astronomy

```bash
cd "$REPO/astronomy"
docker build -t "$IMAGE_REGISTRY/astronomy-frontend:$IMAGE_TAG" ./frontend
docker build --build-arg OTEL_JAVA_AGENT_VERSION="$OTEL_JAVA_AGENT_VERSION" \
             -t "$IMAGE_REGISTRY/astronomy-ad:$IMAGE_TAG" ./ad
docker build -t "$IMAGE_REGISTRY/astronomy-llm:$IMAGE_TAG" ./llm
docker build -t "$IMAGE_REGISTRY/astronomy-email:$IMAGE_TAG" ./email
```

### Florist

```bash
cd "$REPO/florist"
docker build -t "$IMAGE_REGISTRY/florist-frontend:$IMAGE_TAG" ./frontend
docker build --build-arg OTEL_JAVA_AGENT_VERSION="$OTEL_JAVA_AGENT_VERSION" \
             -t "$IMAGE_REGISTRY/florist-ad:$IMAGE_TAG" ./ad
docker build -t "$IMAGE_REGISTRY/florist-llm:$IMAGE_TAG" ./llm
docker build -t "$IMAGE_REGISTRY/florist-image-provider:$IMAGE_TAG" ./image-provider
docker build -t "$IMAGE_REGISTRY/florist-load-generator:$IMAGE_TAG" ./load-generator
docker build -t "$IMAGE_REGISTRY/email:$IMAGE_TAG" ./email
```

## Publish to the registry (maintainers)

```bash
# authenticate once (GitHub Container Registry example)
echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin

# push (astronomy)
for i in astronomy-frontend astronomy-ad astronomy-llm astronomy-email; do
  docker push "$IMAGE_REGISTRY/$i:$IMAGE_TAG"
done

# push (florist)
for i in florist-frontend florist-ad florist-llm florist-image-provider \
         florist-load-generator email; do
  docker push "$IMAGE_REGISTRY/$i:$IMAGE_TAG"
done
```

Verify they are resolvable without pulling layers:

```bash
docker manifest inspect "$IMAGE_REGISTRY/astronomy-frontend:$IMAGE_TAG" >/dev/null && echo ok
# or, via the script:
./deploy.sh images astronomy
./deploy.sh images florist
```

## Load locally into a kind cluster (offline / iterating)

For an offline or air-gapped region cluster, skip the registry and side-load the
freshly-built images. Because the images are tagged with the same
registry-qualified name the package references, and the manifests use
`imagePullPolicy: IfNotPresent`, the loaded image is used and no pull happens.

```bash
export REGION_CLUSTER=ireland   # the kind cluster to load into

# astronomy
for i in astronomy-frontend astronomy-ad astronomy-llm astronomy-email; do
  kind load docker-image "$IMAGE_REGISTRY/$i:$IMAGE_TAG" --name "$REGION_CLUSTER"
done

# florist
for i in florist-frontend florist-ad florist-llm florist-image-provider \
         florist-load-generator email; do
  kind load docker-image "$IMAGE_REGISTRY/$i:$IMAGE_TAG" --name "$REGION_CLUSTER"
done
```

## Via deploy.sh

The script wraps the build + `kind load` above:

```bash
# build + load into every existing kind cluster (or named ones)
./deploy.sh build astronomy
./deploy.sh build florist ireland sweden

# build + load into the region cluster as part of a deploy
BUILD_LOCAL=1 ./deploy.sh ireland astronomy
```

`IMAGE_REGISTRY`, `IMAGE_TAG`, and `OTEL_JAVA_AGENT_VERSION` are all honored as
environment overrides by the script.

## Changing the registry

If you fork or mirror the images elsewhere, set `IMAGE_REGISTRY` when building and
update the references the package uses (the branding value-store / setup-branding
in `app-blueprint/branding/`), then republish the blueprint:

```bash
./deploy.sh blueprint
```
