# Build context: the repository root.
FROM gradle:8.14.3-jdk17 AS build
WORKDIR /src
COPY services/payments ./
RUN gradle --no-daemon -q installDist

FROM eclipse-temurin:17-jre
COPY --from=build /src/build/install/payments /opt/payments
EXPOSE 8081
CMD ["/opt/payments/bin/payments"]
