import type { CalendarEvent } from "./types.js";
import type { CalendarEventWire } from "../protocol.js";

export function mapWireEvent(raw: CalendarEventWire): CalendarEvent {
  return {
    id: raw.id,
    iCalUId: raw.iCalUId,
    changeKey: raw.changeKey,
    title: raw.title,
    start: new Date(raw.start),
    end: new Date(raw.end),
    isAllDay: raw.isAllDay,
    isCancelled: raw.isCancelled,
    response: raw.response,
    showAs: raw.showAs,
    calendarName: raw.calendarName,
    calendarId: raw.calendarId,
  };
}
