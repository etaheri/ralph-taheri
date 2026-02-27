# User Authentication System — PRD

## Problem Statement

Our application currently has no authentication. Users cannot create accounts, log in, or have personalized experiences. We need a basic authentication system to gate access to protected features.

## Target Users

- End users who need personal accounts
- Developers who need to protect API endpoints

## Goals

- Users can sign up with email and password
- Users can log in and receive a session token
- Protected routes require a valid session
- Passwords are securely hashed
- Sessions expire after 24 hours

## Non-Goals

- OAuth/social login (future phase)
- Multi-factor authentication (future phase)
- Role-based access control (future phase)
- Password reset flow (future phase)

## Current State

The application is a Next.js app with a PostgreSQL database. There is no authentication system in place. The database has no user-related tables.

## Proposed Solution

### Overview

Implement a session-based authentication system using bcrypt for password hashing and HTTP-only cookies for session management.

### User Flows

1. **Sign Up**: User fills out form → validate input → hash password → create user row → create session → redirect to dashboard
2. **Log In**: User fills out form → validate input → verify password → create session → redirect to dashboard
3. **Protected Route**: Request hits middleware → check session cookie → validate session → allow or redirect to login
4. **Log Out**: User clicks logout → delete session → redirect to login

### Technical Design

- **Users table**: id, email (unique), password_hash, created_at, updated_at
- **Sessions table**: id, user_id (FK), token (unique), expires_at, created_at
- **Password hashing**: bcrypt with salt rounds = 12
- **Session token**: crypto.randomUUID()
- **Cookie**: HTTP-only, secure, SameSite=Strict, 24h expiry

### Modules

| Module | Type | Description |
|--------|------|-------------|
| db/schema/users | New | User and session table definitions |
| lib/auth | New | Password hashing, session management |
| app/api/auth/* | New | Sign up, log in, log out API routes |
| app/(auth)/login | New | Login page component |
| app/(auth)/signup | New | Signup page component |
| middleware | Modify | Add session validation for protected routes |

## Acceptance Criteria

- [ ] Users can create an account with email and password
- [ ] Users can log in with correct credentials
- [ ] Users see an error for incorrect credentials
- [ ] Protected routes redirect unauthenticated users to login
- [ ] Sessions expire after 24 hours
- [ ] Passwords are hashed with bcrypt (never stored in plaintext)
- [ ] All form inputs are validated (email format, password min length)
- [ ] TypeScript types are defined for all data models
- [ ] Typecheck passes

## Open Questions

- Should we use an ORM (Drizzle/Prisma) or raw SQL?
- What's the minimum password length?

## Dependencies

- bcrypt or bcryptjs package
- PostgreSQL database (already provisioned)
- Next.js middleware (built-in)
