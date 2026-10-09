# The database image, pinned to a registry digest (multi-platform index).
# Tagged boost-togo/postgres:<release> like the other images, so an offline
# server finds it by tag after `docker load`: a digest written directly in
# compose.yaml would not resolve there, since `docker save` does not keep it.
FROM postgres:16.15@sha256:65b16a8b326e0cfbdf33fa7e783f2a0cb352a61448616ccccfd616ef42aa0f65
