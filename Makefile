.PHONY: build check app run clean

build:
	swift build --product MeetingAssistant

check:
	swift run MeetingAssistantChecks

app:
	zsh Scripts/build-app.sh release

run: app
	open .build/MeetingAssistant.app

clean:
	swift package clean
	rm -rf .build/MeetingAssistant.app
