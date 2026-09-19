import Foundation

extension DateExpressionParser {
    /// The closed English vocabulary of the parser. A phrase containing a word outside these tables
    /// and the grammar's structural words ("in", "the", "next", "past", "half", ...) is rejected,
    /// which is how vague input ("someday", "after the meeting") fails instead of being guessed at.
    enum Lexicon {
        /// Gregorian weekday numbers as `Calendar.component(.weekday, from:)` returns them:
        /// 1 = Sunday … 7 = Saturday.
        static let weekdays: [String: Int] = [
            "sunday": 1, "sun": 1,
            "monday": 2, "mon": 2,
            "tuesday": 3, "tue": 3, "tues": 3,
            "wednesday": 4, "wed": 4, "weds": 4,
            "thursday": 5, "thu": 5, "thur": 5, "thurs": 5,
            "friday": 6, "fri": 6,
            "saturday": 7, "sat": 7,
        ]

        static let months: [String: Int] = [
            "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3,
            "april": 4, "apr": 4, "may": 5, "june": 6, "jun": 6, "july": 7, "jul": 7,
            "august": 8, "aug": 8, "september": 9, "sep": 9, "sept": 9,
            "october": 10, "oct": 10, "november": 11, "nov": 11, "december": 12, "dec": 12,
        ]

        /// English names for spoken descriptions, indexed by weekday number - 1 and month number - 1.
        static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        static let monthNames = [
            "January", "February", "March", "April", "May", "June",
            "July", "August", "September", "October", "November", "December",
        ]

        static let cardinalUnits: [String: Int] = [
            "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4,
            "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        ]
        static let cardinalTeens: [String: Int] = [
            "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
            "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
        ]
        static let cardinalTens: [String: Int] = [
            "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
            "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
        ]
        /// Ordinal words; "twenty fifth" and "thirty first" combine a tens word with the first nine.
        static let ordinalWords: [String: Int] = [
            "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
            "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10,
            "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14, "fifteenth": 15,
            "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19,
            "twentieth": 20, "thirtieth": 30,
        ]

        /// Spelling variants, abbreviations and synonyms, rewritten by the tokenizer.
        static let aliases: [String: String] = [
            "tmrw": "tomorrow", "tmr": "tomorrow", "tmrow": "tomorrow", "tomoro": "tomorrow",
            "tomorow": "tomorrow", "tommorow": "tomorrow", "tommorrow": "tomorrow",
            "tonite": "tonight",
            "midday": "noon", "noontime": "noon",
            "hrs": "hours", "hr": "hour", "mins": "minutes", "min": "minute", "wks": "weeks", "wk": "week",
            "until": "till", "til": "till",
            "around": "about", "approximately": "about", "approx": "about", "roughly": "about",
            "fourty": "forty",
        ]

        /// Words that add no meaning and may stand between components: "on friday", "at 3pm",
        /// "by tomorrow", "for next week", "friday of next week", "over the weekend", "3pm sharp".
        static let fillers: Set<String> = [
            "at", "on", "by", "for", "from", "till", "about", "of", "over", "sometime", "sharp", "exactly", "ish",
        ]
    }
}
