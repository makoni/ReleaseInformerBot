import Vapor

func routes(_ app: Application) throws {
	app.get { req async in
		"It works!"
	}

	app.get("hello") { _ async in
		"Hello, world!"
	}
}
