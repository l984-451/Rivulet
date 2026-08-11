// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SentryEventRedaction.swift
//  Rivulet
//
//  The `beforeSend` scrub. Walks every field of an outgoing Sentry event and
//  strips credentials out of it.
//
//  This exists because redacting at the call site is necessary but NOT
//  sufficient. Two of the fields below are populated by the SDK itself and are
//  unreachable from app code:
//
//    • `event.request.url` / `.queryString` — attached by
//      `enableCaptureFailedRequests`, which captures the failing request URL
//      verbatim, token and all.
//    • `event.exceptions[].value` — the NSError description. Foundation embeds
//      the failing URL in `NSURLErrorFailingURLStringErrorKey`, and any custom
//      error whose message interpolates a URL lands here too.
//
//  So this hook is the actual guarantee, and the call-site cleanups are defense
//  in depth. See SensitiveDataRedactor for what counts as a secret and why.
//

import Foundation
import Sentry

nonisolated enum SentryEventRedaction {

    /// Scrubs an event in place and returns it. Never returns nil — dropping is
    /// the caller's decision; this only sanitizes.
    static func redact(_ event: Event) -> Event {
        // The NSError description that becomes the exception value.
        if let exceptions = event.exceptions {
            for exception in exceptions {
                exception.value = SensitiveDataRedactor.redactOptional(exception.value)
            }
        }

        // SDK-populated failed-request context. No call site can reach this, so
        // it has to be handled here.
        if let request = event.request {
            request.url = SensitiveDataRedactor.redactOptional(request.url)
            request.queryString = SensitiveDataRedactor.redactOptional(request.queryString)
            if let headers = request.headers {
                request.headers = headers.mapValues { SensitiveDataRedactor.redact($0) }
            }
            // Cookies are credentials wholesale; never worth shipping.
            if request.cookies != nil {
                request.cookies = SensitiveDataRedactor.redactedValue
            }
        }

        // Anything we attached via scope.setExtra, including response bodies —
        // a Plex error page can echo the request URL back at us.
        if let extra = event.extra {
            event.extra = extra.mapValues(redactAny)
        }

        if let tags = event.tags {
            event.tags = tags.mapValues { SensitiveDataRedactor.redact($0) }
        }

        if let breadcrumbs = event.breadcrumbs {
            for crumb in breadcrumbs {
                crumb.message = SensitiveDataRedactor.redactOptional(crumb.message)
                if let data = crumb.data {
                    crumb.data = data.mapValues(redactAny)
                }
            }
        }

        // `SentryMessage.formatted` is readonly and derived, so rebuild the
        // message from its redacted parts rather than mutating in place.
        if let message = event.message {
            let redactedMessage = SensitiveDataRedactor.redact(message.message ?? message.formatted)
            let rebuilt = SentryMessage(formatted: SensitiveDataRedactor.redact(message.formatted))
            rebuilt.message = redactedMessage
            rebuilt.params = message.params?.map { SensitiveDataRedactor.redact($0) }
            event.message = rebuilt
        }

        return event
    }

    /// Extras and breadcrumb data are `[String: Any]`, so recurse through the
    /// container types the SDK will actually serialize and redact any string or
    /// URL found at the leaves.
    private static func redactAny(_ value: Any) -> Any {
        switch value {
        case let string as String:
            return SensitiveDataRedactor.redact(string)
        case let url as URL:
            return SensitiveDataRedactor.safeURLString(url)
        case let array as [Any]:
            return array.map(redactAny)
        case let dictionary as [String: Any]:
            return dictionary.mapValues(redactAny)
        default:
            // Numbers, dates, bools — nothing to leak.
            return value
        }
    }
}
