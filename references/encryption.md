# Encryption Patterns

This document covers data encryption strategies in PostgreSQL including column-level encryption with pgcrypto, TLS configuration, and sensitive data handling.

## Table of Contents

1. [Overview](#overview)
2. [Encryption Types](#encryption-types)
3. [pgcrypto Extension](#pgcrypto-extension)
4. [Column-Level Encryption](#column-level-encryption)
5. [Key Management](#key-management)
6. [TLS/SSL Configuration](#tlsssl-configuration)
7. [Data Masking](#data-masking)
8. [Best Practices](#best-practices)

## Overview

### Encryption Strategy Decision Tree

```mermaid
flowchart TD
    START([Data Security Need]) --> Q1{What layer?}

    Q1 -->|"In transit"| TLS["TLS/SSL<br/>Client-server encryption"]
    Q1 -->|"At rest (disk)"| Q2{Full disk or selective?}
    Q1 -->|"In database"| Q3{All data or specific columns?}

    Q2 -->|"Full disk"| DISK["OS/Storage encryption<br/>(LUKS, BitLocker)"]
    Q2 -->|"Selective"| TDE["Transparent Data Encryption<br/>(Enterprise feature)"]

    Q3 -->|"Specific columns"| COLUMN["Column-level encryption<br/>(pgcrypto)"]
    Q3 -->|"Application handles"| APP["Application-level encryption"]

    style TLS fill:#c8e6c9
    style COLUMN fill:#c8e6c9
```

### Encryption Comparison

| Approach | Protects Against | Performance Impact | Key Location |
|----------|------------------|-------------------|--------------|
| TLS | Network sniffing | Low | Certificate store |
| Disk encryption | Physical theft | Low | OS/Hardware |
| Column encryption | DB compromise, DBAs | Medium | Application/HSM |
| Application encryption | All above | High | Application |

## Encryption Types

### Symmetric vs Asymmetric

```sql
-- Symmetric (AES): Same key encrypts and decrypts
-- Fast, good for large data
-- Challenge: Key distribution

-- Asymmetric (RSA): Public key encrypts, private key decrypts
-- Slower, good for small data or key exchange
-- Benefit: Public key can be shared

-- Hybrid: Use asymmetric to encrypt symmetric key
-- Best of both worlds
```

## pgcrypto Extension

### Installation

```sql
-- Install pgcrypto extension
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Verify installation
SELECT * FROM pg_extension WHERE extname = 'pgcrypto';
```

### Available Functions

```sql
-- Hashing
digest(data, algorithm)        -- MD5, SHA1, SHA256, SHA384, SHA512
hmac(data, key, algorithm)     -- Keyed hash

-- Password hashing
crypt(password, salt)          -- Blowfish-based hashing
gen_salt(algorithm)            -- Generate salt

-- Symmetric encryption
encrypt(data, key, algorithm)  -- AES, Blowfish, etc.
decrypt(data, key, algorithm)  -- Decrypt

-- Asymmetric encryption (PGP)
pgp_sym_encrypt(data, password)
pgp_sym_decrypt(data, password)
pgp_pub_encrypt(data, key)
pgp_pub_decrypt(data, key)

-- Random data
gen_random_bytes(count)
gen_random_uuid()
```

### Basic Encryption Example

```sql
-- Symmetric encryption with AES
SELECT encrypt('sensitive data', 'my-secret-key', 'aes');
-- Returns: \x... (bytea)

SELECT convert_from(
    decrypt('\x...', 'my-secret-key', 'aes'),
    'UTF8'
);
-- Returns: sensitive data

-- PGP symmetric encryption (includes integrity check)
SELECT pgp_sym_encrypt('sensitive data', 'my-password');
-- Returns: \x... (bytea)

SELECT pgp_sym_decrypt('\x...', 'my-password');
-- Returns: sensitive data
```

## Column-Level Encryption

### Table Design with Encrypted Columns

```sql
CREATE TABLE data.users (
    id              uuid PRIMARY KEY DEFAULT uuidv7(),
    email           text NOT NULL UNIQUE,  -- Not encrypted (for lookups)
    email_hash      text NOT NULL,         -- For searching encrypted email

    -- Encrypted sensitive data
    ssn_encrypted   bytea,
    phone_encrypted bytea,

    -- Non-sensitive data
    name            text NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now()
);

-- Index on hash for searching
CREATE INDEX users_email_hash_idx ON data.users(email_hash);
```

### Encryption Helper Functions

```sql
-- Encrypt sensitive data
CREATE FUNCTION private.encrypt_sensitive(in_data text, in_key text)
RETURNS bytea
LANGUAGE sql
IMMUTABLE
STRICT
AS $$
    SELECT pgp_sym_encrypt(in_data, in_key, 'cipher-algo=aes256');
$$;

-- Decrypt sensitive data
CREATE FUNCTION private.decrypt_sensitive(in_data bytea, in_key text)
RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
AS $$
    SELECT pgp_sym_decrypt(in_data, in_key);
$$;

-- Generate searchable hash (for encrypted columns)
CREATE FUNCTION private.hash_for_search(in_data text, in_salt text)
RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
AS $$
    SELECT encode(digest(lower(in_data) || in_salt, 'sha256'), 'hex');
$$;
```

### API Functions with Encryption

```sql
-- Insert with encryption
CREATE PROCEDURE api.insert_user(
    in_email text,
    in_ssn text,
    in_phone text,
    in_name text,
    INOUT io_id uuid DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, private, pg_temp
AS $$
DECLARE
    l_encryption_key text;
    l_hash_salt text;
BEGIN
    -- Get keys from secure configuration
    l_encryption_key := current_setting('app.encryption_key');
    l_hash_salt := current_setting('app.hash_salt');

    INSERT INTO data.users (
        email,
        email_hash,
        ssn_encrypted,
        phone_encrypted,
        name
    ) VALUES (
        in_email,
        private.hash_for_search(in_email, l_hash_salt),
        private.encrypt_sensitive(in_ssn, l_encryption_key),
        private.encrypt_sensitive(in_phone, l_encryption_key),
        in_name
    )
    RETURNING id INTO io_id;
END;
$$;

-- Select with decryption
CREATE FUNCTION api.get_user_details(in_user_id uuid)
RETURNS TABLE (
    id uuid,
    email text,
    ssn text,
    phone text,
    name text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, private, pg_temp
AS $$
DECLARE
    l_encryption_key text;
BEGIN
    l_encryption_key := current_setting('app.encryption_key');

    RETURN QUERY
    SELECT
        u.id,
        u.email,
        private.decrypt_sensitive(u.ssn_encrypted, l_encryption_key) AS ssn,
        private.decrypt_sensitive(u.phone_encrypted, l_encryption_key) AS phone,
        u.name
    FROM data.users u
    WHERE u.id = in_user_id;
END;
$$;
```

### Searchable Encryption

```sql
-- Search by encrypted email using hash
CREATE FUNCTION api.find_user_by_email(in_email text)
RETURNS TABLE (
    id uuid,
    email text,
    name text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, private, pg_temp
AS $$
DECLARE
    l_hash_salt text;
    l_email_hash text;
BEGIN
    l_hash_salt := current_setting('app.hash_salt');
    l_email_hash := private.hash_for_search(in_email, l_hash_salt);

    RETURN QUERY
    SELECT u.id, u.email, u.name
    FROM data.users u
    WHERE u.email_hash = l_email_hash;
END;
$$;
```

## Key Management

### Key Storage Options

```sql
-- Option 1: PostgreSQL GUC variables (set at connection)
-- Set in postgresql.conf or per-session
-- NOT RECOMMENDED for production (visible in logs, pg_settings)
SET app.encryption_key = 'secret-key';

-- Option 2: Environment variables via file
-- Create file with restricted permissions
-- Reference in postgresql.conf:
-- app.encryption_key = 'include:/path/to/keyfile'

-- Option 3: External secrets manager (recommended)
-- Application retrieves key and passes to database
-- Key never stored in database
```

### Key Rotation Pattern

```sql
-- Table to track encryption key versions
CREATE TABLE private.encryption_keys (
    key_id          integer PRIMARY KEY,
    key_hash        text NOT NULL,  -- Hash of key for verification
    created_at      timestamptz NOT NULL DEFAULT now(),
    retired_at      timestamptz,
    is_active       boolean NOT NULL DEFAULT true
);

-- Add key_version to encrypted tables
ALTER TABLE data.users ADD COLUMN encryption_key_id integer DEFAULT 1;

-- Re-encryption procedure
CREATE PROCEDURE private.rotate_encryption_key(
    in_old_key text,
    in_new_key text,
    in_new_key_id integer
)
LANGUAGE plpgsql
AS $$
DECLARE
    l_user record;
BEGIN
    FOR l_user IN
        SELECT id, ssn_encrypted, phone_encrypted
        FROM data.users
        WHERE encryption_key_id != in_new_key_id
        FOR UPDATE
    LOOP
        UPDATE data.users
        SET
            ssn_encrypted = private.encrypt_sensitive(
                private.decrypt_sensitive(l_user.ssn_encrypted, in_old_key),
                in_new_key
            ),
            phone_encrypted = private.encrypt_sensitive(
                private.decrypt_sensitive(l_user.phone_encrypted, in_old_key),
                in_new_key
            ),
            encryption_key_id = in_new_key_id
        WHERE id = l_user.id;

        -- Commit in batches to avoid long transaction
        IF l_user.id::text LIKE '%0' THEN
            COMMIT;
        END IF;
    END LOOP;
END;
$$;
```

### Hardware Security Module (HSM) Integration

```sql
-- For HSM integration, encryption/decryption happens outside PostgreSQL
-- Database stores only encrypted blobs

-- Example with external encryption (pseudocode)
-- 1. Application encrypts data using HSM
-- 2. Encrypted blob sent to PostgreSQL
-- 3. Retrieval: encrypted blob returned to application
-- 4. Application decrypts using HSM

CREATE TABLE data.hsm_encrypted_data (
    id              uuid PRIMARY KEY DEFAULT uuidv7(),
    key_id          text NOT NULL,          -- HSM key identifier
    encrypted_data  bytea NOT NULL,         -- HSM-encrypted blob
    created_at      timestamptz NOT NULL DEFAULT now()
);
```

## TLS/SSL Configuration

### Server Configuration

```bash
# postgresql.conf
ssl = on
ssl_cert_file = '/path/to/server.crt'
ssl_key_file = '/path/to/server.key'
ssl_ca_file = '/path/to/ca.crt'      # For client cert verification
ssl_crl_file = '/path/to/crl.pem'    # Certificate revocation list

# Minimum TLS version
ssl_min_protocol_version = 'TLSv1.2'

# Cipher suites (strong ciphers only)
ssl_ciphers = 'HIGH:MEDIUM:+3DES:!aNULL'

# Prefer server cipher order
ssl_prefer_server_ciphers = on
```

### Require SSL in pg_hba.conf

```bash
# Require SSL for all remote connections
hostssl all all 0.0.0.0/0 scram-sha-256
hostssl all all ::0/0 scram-sha-256

# Allow non-SSL only for local
local all all peer
host all all 127.0.0.1/32 scram-sha-256
```

### Client Connection with SSL

```bash
# Connection string
postgresql://user:pass@host:5432/db?sslmode=verify-full&sslrootcert=/path/to/ca.crt

# psql
psql "host=server dbname=mydb sslmode=verify-full sslrootcert=/path/to/ca.crt"
```

### SSL Modes

| Mode | Encryption | Certificate Verification |
|------|------------|-------------------------|
| disable | No | No |
| allow | If available | No |
| prefer | If available | No |
| require | Yes | No |
| verify-ca | Yes | CA only |
| verify-full | Yes | CA + hostname |

### Verify SSL Connection

```sql
-- Check if connection is encrypted
SELECT ssl, version, cipher FROM pg_stat_ssl WHERE pid = pg_backend_pid();

-- All active SSL connections
SELECT
    usename,
    client_addr,
    ssl,
    version,
    cipher,
    bits
FROM pg_stat_ssl
JOIN pg_stat_activity ON pg_stat_ssl.pid = pg_stat_activity.pid;
```

## Data Masking

### Dynamic Data Masking

```sql
-- Masking functions
CREATE FUNCTION private.mask_email(in_email text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT
        substring(in_email from 1 for 2) ||
        repeat('*', position('@' in in_email) - 3) ||
        substring(in_email from position('@' in in_email));
    -- john.doe@example.com → jo*****@example.com
$$;

CREATE FUNCTION private.mask_phone(in_phone text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT
        regexp_replace(in_phone, '(\d{3})\d{4}(\d{4})', '\1****\2');
    -- 1234567890 → 123****7890
$$;

CREATE FUNCTION private.mask_ssn(in_ssn text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT 'XXX-XX-' || right(in_ssn, 4);
    -- 123-45-6789 → XXX-XX-6789
$$;

CREATE FUNCTION private.mask_credit_card(in_cc text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT repeat('*', length(in_cc) - 4) || right(in_cc, 4);
    -- 4111111111111111 → ************1111
$$;
```

### Role-Based Data Access

```sql
-- Create view with conditional masking
CREATE VIEW api.v_users AS
SELECT
    id,
    CASE
        WHEN current_setting('app.role', true) = 'admin'
        THEN email
        ELSE private.mask_email(email)
    END AS email,
    CASE
        WHEN current_setting('app.role', true) = 'admin'
        THEN private.decrypt_sensitive(ssn_encrypted, current_setting('app.encryption_key'))
        ELSE private.mask_ssn(
            private.decrypt_sensitive(ssn_encrypted, current_setting('app.encryption_key'))
        )
    END AS ssn,
    name,
    created_at
FROM data.users;

-- Set role before querying
SET app.role = 'admin';  -- Full access
SET app.role = 'user';   -- Masked data
```

### Static Data Masking (for non-production)

```sql
-- Procedure to mask data for dev/test environments
CREATE PROCEDURE private.mask_for_nonprod()
LANGUAGE plpgsql
AS $$
BEGIN
    -- Mask emails
    UPDATE data.users
    SET email = 'user' || id || '@example.com';

    -- Randomize SSN (keep format)
    UPDATE data.users
    SET ssn_encrypted = private.encrypt_sensitive(
        lpad((random() * 999)::integer::text, 3, '0') || '-' ||
        lpad((random() * 99)::integer::text, 2, '0') || '-' ||
        lpad((random() * 9999)::integer::text, 4, '0'),
        current_setting('app.encryption_key')
    );

    -- Randomize phone numbers
    UPDATE data.users
    SET phone_encrypted = private.encrypt_sensitive(
        lpad((random() * 9999999999)::bigint::text, 10, '0'),
        current_setting('app.encryption_key')
    );
END;
$$;
```

## Best Practices

### Password Storage

```sql
-- NEVER store plain passwords
-- Use bcrypt via crypt()

CREATE FUNCTION private.hash_password(in_password text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT crypt(in_password, gen_salt('bf', 10));  -- Blowfish, cost 10
$$;

CREATE FUNCTION private.verify_password(in_password text, in_hash text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT crypt(in_password, in_hash) = in_hash;
$$;

-- Usage
INSERT INTO data.users (email, password_hash)
VALUES ('user@example.com', private.hash_password('secret123'));

-- Verify
SELECT private.verify_password('secret123', password_hash)
FROM data.users WHERE email = 'user@example.com';
```

### Audit Encrypted Data Access

```sql
-- Log access to sensitive data
CREATE TABLE data.sensitive_data_access_log (
    id              uuid PRIMARY KEY DEFAULT uuidv7(),
    table_name      text NOT NULL,
    record_id       uuid NOT NULL,
    accessed_by     text NOT NULL DEFAULT current_user,
    accessed_at     timestamptz NOT NULL DEFAULT now(),
    access_type     text NOT NULL,  -- 'view', 'decrypt'
    client_ip       inet DEFAULT inet_client_addr()
);

-- Wrapper function that logs access
CREATE FUNCTION api.get_user_ssn(in_user_id uuid)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, private, pg_temp
AS $$
DECLARE
    l_ssn text;
BEGIN
    -- Log the access
    INSERT INTO data.sensitive_data_access_log (table_name, record_id, access_type)
    VALUES ('users', in_user_id, 'decrypt');

    -- Return decrypted data
    SELECT private.decrypt_sensitive(ssn_encrypted, current_setting('app.encryption_key'))
    INTO l_ssn
    FROM data.users WHERE id = in_user_id;

    RETURN l_ssn;
END;
$$;
```

### Security Checklist

```markdown
## Encryption Security Checklist

### Key Management
- [ ] Keys stored outside database
- [ ] Keys rotated periodically
- [ ] Key access logged
- [ ] Separate keys per environment
- [ ] Key backup procedure documented

### Data Protection
- [ ] PII identified and encrypted
- [ ] Encryption algorithms current (AES-256)
- [ ] Hash salts unique per record/type
- [ ] Sensitive data masked in logs

### Network Security
- [ ] TLS enabled and enforced
- [ ] TLS 1.2+ only
- [ ] Certificate validation enabled
- [ ] Certificates rotated before expiry

### Access Control
- [ ] Decryption limited to necessary roles
- [ ] Audit logging for sensitive data access
- [ ] Non-production environments use masked data
```
