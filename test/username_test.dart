import 'package:flutter_test/flutter_test.dart';
import 'package:meridian/models/username.dart';

void main() {
  group('slugifyFragment', () {
    test('lowercases and keeps alphanumerics', () {
      expect(slugifyFragment('Aarav'), 'aarav');
      expect(slugifyFragment('Sharma2024'), 'sharma2024');
    });

    test('replaces spaces and punctuation with a dot', () {
      expect(slugifyFragment('Aarav Sharma'), 'aarav.sharma');
      expect(slugifyFragment("O'Brien"), 'o.brien');
      expect(slugifyFragment('a/b'), 'a.b');
    });

    test('folds accents rather than dropping the letter', () {
      expect(slugifyFragment('José'), 'jose');
      expect(slugifyFragment('Ångström'), 'angstrom');
      expect(slugifyFragment('François'), 'francois');
    });

    test('drops non-Latin scripts', () {
      expect(slugifyFragment('李雷'), '');
      expect(slugifyFragment('Ravi 李'), 'ravi.');
    });
  });

  group('usernameFrom', () {
    test('joins first and surname with a dot', () {
      expect(
        usernameFrom(firstName: 'Aarav', surname: 'Sharma'),
        'aarav.sharma',
      );
    });

    test('collapses runs of separators', () {
      expect(
        usernameFrom(firstName: '  Aarav   Kumar  ', surname: '  Sharma '),
        'aarav.kumar.sharma',
      );
    });

    test('drops leading and trailing separators', () {
      expect(usernameFrom(firstName: '.Ana.', surname: '.Dias.'), 'ana.dias');
    });

    test('uses the first name alone when there is no surname', () {
      expect(usernameFrom(firstName: 'Aarav', surname: ''), 'aarav');
    });

    test('uses the surname alone when there is no first name', () {
      expect(usernameFrom(firstName: '', surname: 'Sharma'), 'sharma');
    });

    test('keeps a short result at or above the minimum length', () {
      // "Li" alone is below kUsernameMinLength, so it must be padded.
      final result = usernameFrom(firstName: 'Li', surname: '');
      expect(result.length, greaterThanOrEqualTo(kUsernameMinLength));
    });

    test('never exceeds the maximum length', () {
      final result = usernameFrom(
        firstName: 'Bartholomew',
        surname: 'Featherstonehaugh',
      );
      expect(result.length, lessThanOrEqualTo(kUsernameMaxLength));
    });

    test('returns empty when there is nothing usable', () {
      expect(usernameFrom(firstName: '李雷', surname: '韩梅梅'), '');
    });
  });

  group('usernameCandidates', () {
    test('offers the base name first, then numbered variants', () {
      final candidates = usernameCandidates(
        firstName: 'Aarav',
        surname: 'Sharma',
        limit: 3,
      );
      expect(candidates.first, 'aarav.sharma');
      expect(candidates[1], 'aarav.sharma.2');
      expect(candidates[2], 'aarav.sharma.3');
    });

    test('appends a stable hash when an identity is supplied', () {
      final a = usernameCandidates(
        firstName: 'Aarav',
        surname: 'Sharma',
        identity: '2024XXXX',
        limit: 2,
      );
      final b = usernameCandidates(
        firstName: 'Aarav',
        surname: 'Sharma',
        identity: '2024XXXX',
        limit: 2,
      );
      expect(a, equals(b), reason: 'same identity must give same fallback');
      expect(a.last, isNot(a.first));
    });

    test('is empty when the name yields nothing', () {
      expect(usernameCandidates(firstName: '李', surname: '雷'), isEmpty);
    });
  });

  group('validateUsername', () {
    test('accepts a well-formed username', () {
      expect(validateUsername('aarav.sharma').isValid, isTrue);
      expect(validateUsername('r_2024').isValid, isTrue);
      expect(validateUsername('abc').isValid, isTrue);
    });

    test('rejects empty and over-long', () {
      expect(validateUsername('').problem, UsernameProblem.empty);
      expect(
        validateUsername('a' * (kUsernameMaxLength + 1)).problem,
        UsernameProblem.tooLong,
      );
    });

    test('rejects too short', () {
      expect(validateUsername('ab').problem, UsernameProblem.tooShort);
    });

    test('rejects disallowed characters', () {
      expect(
        validateUsername('aarav sharma').problem,
        UsernameProblem.badCharacters,
      );
      expect(
        validateUsername('aarav-sharma').problem,
        UsernameProblem.badCharacters,
      );
      expect(
        validateUsername('aarav@sharma').problem,
        UsernameProblem.badCharacters,
      );
      expect(validateUsername('José').problem, UsernameProblem.badCharacters);
    });

    test('rejects leading and trailing separators', () {
      expect(
        validateUsername('.aarav').problem,
        UsernameProblem.startsWithSeparator,
      );
      expect(
        validateUsername('aarav.').problem,
        UsernameProblem.endsWithSeparator,
      );
    });

    test('rejects repeated separators', () {
      expect(
        validateUsername('aarav..sharma').problem,
        UsernameProblem.repeatedSeparators,
      );
      expect(
        validateUsername('aarav__sharma').problem,
        UsernameProblem.repeatedSeparators,
      );
    });

    test('rejects reserved names regardless of case', () {
      expect(validateUsername('admin').problem, UsernameProblem.reserved);
      expect(validateUsername('ADMIN').problem, UsernameProblem.reserved);
      expect(validateUsername('Meridian').problem, UsernameProblem.reserved);
      expect(isReserved('support'), isTrue);
    });

    test('every rejection carries a message for the UI', () {
      for (final input in ['', 'ab', 'a b', '.ab', 'ab.', 'a..b', 'admin']) {
        expect(
          validateUsername(input).message,
          isNotNull,
          reason: 'no message for "$input"',
        );
      }
    });

    test('a valid username has no message', () {
      expect(validateUsername('aarav.sharma').message, isNull);
    });
  });

  group('generated names are always valid', () {
    test('usernameFrom output passes validation', () {
      const names = [
        ('Aarav', 'Sharma'),
        ('Li', ''),
        ('Meera', 'Iyer'),
        ('Bartholomew', 'Featherstonehaugh'),
        ('José', 'Díaz'),
        ('  spaced  ', '  out  '),
      ];
      for (final (first, last) in names) {
        final generated = usernameFrom(firstName: first, surname: last);
        if (generated.isEmpty) continue;
        expect(
          validateUsername(generated).isValid,
          isTrue,
          reason: '"$first $last" produced invalid "$generated"',
        );
      }
    });

    test('every numbered candidate also passes validation', () {
      final candidates = usernameCandidates(
        firstName: 'Aarav',
        surname: 'Sharma',
        identity: '2024XXXX',
      );
      for (final candidate in candidates) {
        expect(
          validateUsername(candidate).isValid,
          isTrue,
          reason: 'candidate "$candidate" is invalid',
        );
      }
    });
  });
}