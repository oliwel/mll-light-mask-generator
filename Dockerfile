FROM openscad/openscad:trixie

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY server.py house_mask.scad index.html ./

EXPOSE 8080

CMD ["python3", "server.py"]
