-- ==============================================================================
-- AlmaLinux 9 / RHEL VPS MariaDB Database Initial Schema
-- Repository: almalinux-nodejs-vps-deploykit
-- Description: Production-ready baseline schema with UTF8MB4 and audit logging
-- ==============================================================================

-- Enforce strict SQL mode and UTF8MB4 encoding
SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS = 0;

-- ------------------------------------------------------------------------------
-- Table: app_migrations (Schema Versioning)
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `app_migrations` (
    `id` INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    `version` VARCHAR(100) NOT NULL UNIQUE,
    `description` VARCHAR(255) NULL,
    `applied_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ------------------------------------------------------------------------------
-- Table: users (Application Identity and Role-Based Access)
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `users` (
    `id` BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    `email` VARCHAR(191) NOT NULL UNIQUE,
    `password_hash` VARCHAR(255) NOT NULL,
    `full_name` VARCHAR(100) NOT NULL,
    `role` ENUM('admin', 'operator', 'user') NOT NULL DEFAULT 'user',
    `status` ENUM('active', 'suspended', 'pending') NOT NULL DEFAULT 'active',
    `last_login_at` TIMESTAMP NULL DEFAULT NULL,
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX `idx_users_role_status` (`role`, `status`),
    INDEX `idx_users_created_at` (`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ------------------------------------------------------------------------------
-- Table: app_settings (Key-Value Dynamic Configuration)
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `app_settings` (
    `key` VARCHAR(100) NOT NULL PRIMARY KEY,
    `value` TEXT NOT NULL,
    `description` VARCHAR(255) NULL,
    `is_sensitive` BOOLEAN NOT NULL DEFAULT FALSE,
    `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ------------------------------------------------------------------------------
-- Table: audit_logs (Enterprise Security & Deployment Audit Trail)
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `audit_logs` (
    `id` BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    `user_id` BIGINT UNSIGNED NULL,
    `action` VARCHAR(100) NOT NULL,
    `entity` VARCHAR(100) NULL,
    `entity_id` VARCHAR(100) NULL,
    `details` JSON NULL,
    `ip_address` VARCHAR(45) NULL,
    `user_agent` VARCHAR(255) NULL,
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX `idx_audit_user_id` (`user_id`),
    INDEX `idx_audit_action` (`action`),
    INDEX `idx_audit_created_at` (`created_at`),
    CONSTRAINT `fk_audit_user` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ------------------------------------------------------------------------------
-- Seed Initial Baseline Data
-- ------------------------------------------------------------------------------
INSERT INTO `app_migrations` (`version`, `description`)
VALUES ('v1.0.0_baseline', 'Initial production schema baseline')
ON DUPLICATE KEY UPDATE `description` = VALUES(`description`);

INSERT INTO `app_settings` (`key`, `value`, `description`, `is_sensitive`)
VALUES 
    ('maintenance_mode', 'false', 'Toggle global maintenance window', FALSE),
    ('app_name', 'DeployKit Node.js VPS Service', 'Display name of application instance', FALSE),
    ('max_upload_bytes', '10485760', 'Maximum allowable upload payload (10MB)', FALSE)
ON DUPLICATE KEY UPDATE `description` = VALUES(`description`);

SET FOREIGN_KEY_CHECKS = 1;
