# Apache Ranger Admin 2.6.0 — multi-stage build from Apache source tarball.
# Stage 1 compiles with Maven; stage 2 is the lean JRE runtime image.
# Built into minikube's Docker daemon via: make ranger-image
#
# First build downloads ~300 MB of Maven dependencies; subsequent builds use
# Docker's layer cache (or BuildKit's Maven cache mount).
#
# Environment variables (all set by Helm at runtime):
#   DB_HOST              MySQL hostname  (default: mysql)
#   DB_ROOT_PASSWORD     MySQL root password for schema init
#   DB_NAME              Database name   (default: ranger_db)
#   DB_USER              Ranger DB user  (default: ranger_user)
#   DB_PASSWORD          Ranger DB user password
#   RANGER_ADMIN_PASSWORD  Admin UI password (min 8 chars, mixed case + digit required)
#   POLICYMGR_URL        External URL of this Ranger Admin (for policy downloads)

# ---------------------------------------------------------------------------
# Stage 1: Maven build
# ---------------------------------------------------------------------------
FROM maven:3.9-eclipse-temurin-11 AS builder

ARG RANGER_VERSION=2.6.0

WORKDIR /src

# ranger-util's antrun plugin calls python3 during code generation
RUN apt-get update && apt-get install -y --no-install-recommends python3 && \
    rm -rf /var/lib/apt/lists/*

# Download and extract the Apache source tarball (~5 MB)
RUN curl -fL \
    "https://downloads.apache.org/ranger/${RANGER_VERSION}/apache-ranger-${RANGER_VERSION}.tar.gz" \
    -o /tmp/ranger-src.tar.gz && \
    tar xzf /tmp/ranger-src.tar.gz --strip-components=1 && \
    rm /tmp/ranger-src.tar.gz

# Build all modules (DskipTests + parallel).
# Output: /src/target/ranger-${RANGER_VERSION}-admin.tar.gz
# Note: distro/pom.xml writes all assembly tarballs to ../target/ (the root target/).
RUN mvn package \
        -DskipTests \
        -Dmaven.test.skip=true \
        -Denunciate.skip=true \
        --no-transfer-progress \
        -T 4 \
    2>&1 | tail -60

RUN test -f /src/target/ranger-${RANGER_VERSION}-admin.tar.gz || \
    { echo "Admin tarball not found!"; ls /src/target/*.tar.gz 2>/dev/null; exit 1; }

# ---------------------------------------------------------------------------
# Stage 2: Runtime image
# ---------------------------------------------------------------------------
FROM eclipse-temurin:11-jre-jammy

ARG RANGER_VERSION=2.6.0

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 default-mysql-client && \
    rm -rf /var/lib/apt/lists/*

# setup.sh expects a 'ranger' OS user to exist
RUN groupadd -r ranger && useradd -r -g ranger -s /bin/false -m ranger

# Extract the Ranger Admin binary built in stage 1
COPY --from=builder /src/target/ranger-${RANGER_VERSION}-admin.tar.gz /tmp/ranger-admin.tar.gz
RUN tar xzf /tmp/ranger-admin.tar.gz -C /opt && \
    mv /opt/ranger-${RANGER_VERSION}-admin /opt/ranger-admin && \
    rm /tmp/ranger-admin.tar.gz && \
    chown -R ranger:ranger /opt/ranger-admin

# MySQL JDBC connector used by jisql for DB connectivity in setup.sh
RUN curl -fL \
    "https://repo1.maven.org/maven2/com/mysql/mysql-connector-j/8.0.33/mysql-connector-j-8.0.33.jar" \
    -o /opt/ranger-admin/jisql/lib/mysql-connector-j-8.0.33.jar

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /opt/ranger-admin
EXPOSE 6080

ENTRYPOINT ["/entrypoint.sh"]
