#Week 1 –  Onboarding & Profile Setup

Objective: Doctor registration, verification, and profile completion.

Flow

Register → Verify → Setup Profile → Set Availability

Entities

Doctor, Profile, VerificationToken, Specialization

Relationships

Doctor–Profile (1:1)

Doctor–VerificationToken (1:N)

Doctor–Specialization (1:N)

APIs

POST /register

GET /verify

PUT /profile

PUT /availability

Tables

doctors, profiles, verification_tokens, specializations
