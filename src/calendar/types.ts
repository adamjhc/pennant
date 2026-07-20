export interface CalendarEvent {
  id: string;
  /** Stable external identifier when available; falls back to id */
  iCalUId: string | null;
  changeKey: string | null;
  title: string;
  start: Date;
  end: Date;
  isAllDay: boolean;
  isCancelled: boolean;
  response: string | null;
  showAs: string | null;
  calendarName: string;
  calendarId: string;
}

export interface LocalCalendar {
  id: string;
  title: string;
  source: string | null;
  type: string;
}
