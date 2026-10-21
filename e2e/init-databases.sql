-- One Postgres, one database per service, as each service owns its data.
CREATE DATABASE catalog;
CREATE DATABASE orders;
CREATE DATABASE notifications;
