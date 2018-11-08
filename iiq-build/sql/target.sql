CREATE DATABASE IF NOT EXISTS target;

USE target;

DROP TABLE IF EXISTS users;
DROP TABLE IF EXISTS roles;
DROP TABLE IF EXISTS roles_users;

CREATE TABLE users (username VARCHAR(200), first_name VARCHAR(200), middle_name VARCHAR(200), last_name VARCHAR(200), display_name VARCHAR(200), emplid VARCHAR(200), manager_username VARCHAR(200), enabled VARCHAR(5));

CREATE TABLE roles (role_name VARCHAR(80));
INSERT INTO roles (role_name) VALUES ("System Administrators");
INSERT INTO roles (role_name) VALUES ("IT Support");
INSERT INTO roles (role_name) VALUES ("Ledger Admins");
INSERT INTO roles (role_name) VALUES ("Auditors");
INSERT INTO roles (role_name) VALUES ("Expense Entry");
INSERT INTO roles (role_name) VALUES ("Expense Approvers");
INSERT INTO roles (role_name) VALUES ("Payroll Managers");
INSERT INTO roles (role_name) VALUES ("Fulfillers");
INSERT INTO roles (role_name) VALUES ("End Users");

CREATE TABLE roles_users (username VARCHAR(200), role_name VARCHAR(200));

GRANT SELECT ON target.* to 'identityiq';
GRANT UPDATE ON target.users to 'identityiq';
GRANT UPDATE ON target.roles_users to 'identityiq';
GRANT INSERT ON target.users to 'identityiq';
GRANT INSERT ON target.roles_users to 'identityiq';
