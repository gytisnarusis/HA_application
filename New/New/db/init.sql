CREATE DATABASE login_data;
use login_data;

CREATE TABLE user (
    id int(11),
    name VARCHAR(30),
    password VARCHAR(30),
    email VARCHAR(255)
);