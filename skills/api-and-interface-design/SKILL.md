---
name: api-and-interface-design
description: "Designs or changes public APIs, module boundaries, request/response contracts, events, schemas, or cross-component interfaces where compatibility and failure semantics matter."
---

# API and Interface Design

1. Identify consumers, producer, trust boundary, lifecycle, and compatibility promise.
2. Define inputs, outputs, invariants, validation, errors, idempotency, ordering, pagination, and cancellation only where relevant.
3. Make invalid states difficult to express. Prefer small stable contracts and existing repository conventions over new abstractions.
4. For a breaking change, describe migration, coexistence window, and rollback. Do not silently reinterpret an existing field.
5. Verify with contract tests or the narrowest producer/consumer integration.

Return the contract, examples for success and failure, compatibility impact, verification, and unresolved decisions. Keep transport-specific detail behind the contract and avoid speculative versioning or extensibility.
