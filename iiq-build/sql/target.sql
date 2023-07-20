CREATE DATABASE IF NOT EXISTS target;

USE target;

DROP TABLE IF EXISTS roles_permissions;
DROP TABLE IF EXISTS roles_users;
DROP TABLE IF EXISTS users;
DROP TABLE IF EXISTS roles;

CREATE TABLE users
(
    username         VARCHAR(200),
    first_name       VARCHAR(200),
    middle_name      VARCHAR(200),
    last_name        VARCHAR(200),
    display_name     VARCHAR(200),
    emplid           VARCHAR(200),
    manager_username VARCHAR(200),
    enabled          VARCHAR(5),

    primary key (username),
    constraint ux_emplid unique (emplid)
);

CREATE TABLE roles
(
    role_name VARCHAR(80),
    primary key (role_name)
);

INSERT INTO roles (role_name)
VALUES ('System Administrators'),
       ('IT Support'),
       ('Ledger Admins'),
       ('Auditors'),
       ('Expense Entry'),
       ('Expense Approvers'),
       ('Expense Signers'),
       ('Payroll Managers'),
       ('Fulfillers'),
       ('Accounting Analyst'),
       ('End Users');

CREATE TABLE roles_permissions
(
    permission VARCHAR(80),
    role_name  VARCHAR(80),

    CONSTRAINT FOREIGN KEY (role_name) references roles (role_name) on delete cascade
);

INSERT INTO roles_permissions (role_name, permission)
values ('System Administrators', 'admin'),
       ('System Administrators', 'read_all'),
       ('System Administrators', 'write_all'),
       ('System Administrators', 'read_it'),
       ('IT Support', 'admin'),
       ('IT Support', 'read_it'),
       ('Ledger Admins', 'read_ledger'),
       ('Ledger Admins', 'write_ledger'),
       ('Auditors', 'read_ledger'),
       ('Auditors', 'read_payroll'),
       ('Auditors', 'read_job'),
       ('Auditors', 'approve_payroll'),
       ('Expense Entry', 'write_expense'),
       ('Expense Entry', 'read_ledger'),
       ('Expense Entry', 'read_expense'),
       ('Expense Approvers', 'read_expense'),
       ('Expense Approvers', 'approve_expense'),
       ('Expense Signers', 'read_expense'),
       ('Expense Signers', 'sign_expense'),
       ('Expense Signers', 'write_expense'),
       ('Payroll Managers', 'read_payroll'),
       ('Payroll Managers', 'write_payroll'),
       ('Fulfillers', 'read_ledger'),
       ('Fulfillers', 'write_job'),
       ('Fulfillers', 'read_job'),
       ('Accounting Analyst', 'read_ledger'),
       ('Accounting Analyst', 'write_ledger'),
       ('End Users', 'read_expense'),
       ('End Users', 'read_job')
;

CREATE TABLE roles_users
(
    username  VARCHAR(200),
    role_name VARCHAR(200),

    CONSTRAINT FOREIGN KEY (username) references users (username) on delete cascade,
    CONSTRAINT FOREIGN KEY (role_name) references roles (role_name) on delete cascade
);

INSERT INTO users (username, first_name, middle_name, last_name, display_name,
                   emplid, manager_username, enabled)
values ('admin', 'System', NULL, 'Administrator', 'System Administrator',
        '000000', NULL, 'TRUE');

INSERT INTO roles_users (username, role_name)
values ('admin', 'System Administrators');


GRANT SELECT ON target.* to 'identityiq';
GRANT UPDATE ON target.users to 'identityiq';
GRANT UPDATE ON target.roles_users to 'identityiq';
GRANT INSERT ON target.users to 'identityiq';
GRANT INSERT ON target.roles_users to 'identityiq';
